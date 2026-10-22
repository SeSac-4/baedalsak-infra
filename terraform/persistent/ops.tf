# =============================================================================
# 운영 자동화 (그림 v6 B안)
#   켜기·끄기 : EventBridge Scheduler(평일 09:00·19:00 KST) → Step Functions → Lambda ① → GitHub Actions
#              워크플로가 작업 토큰으로 결과 보고 → SNS alerts → 메일
#   알람      : CloudWatch 알람(ephemeral/alarms.tf) → SNS alerts → 메일 (ALERT_EMAILS, 구독 확인 메일 1회 클릭)
#   예산      : Budgets(일일) 80% 메일 · 100% 메일 + SNS budget → Lambda ③ → Step Functions(action=down)
#   값은 콘솔에서 넣음 (Terraform 은 빈 Secret 만 만듦):
#     <SECRET_PREFIX>/github-dispatch  GitHub fine-grained PAT (이 레포, Actions: Read and write)
# =============================================================================

resource "aws_secretsmanager_secret" "github_dispatch" {
  name                    = "${local.secret_prefix}/github-dispatch"
  recovery_window_in_days = 0
}

# ---------- SNS ----------
resource "aws_sns_topic" "alerts" {
  name = "${local.name}-alerts"
}

resource "aws_sns_topic_subscription" "alerts_email" {
  for_each  = toset(var.alert_emails)
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = each.value
}

resource "aws_sns_topic" "budget" {
  name = "${local.name}-budget"
}

data "aws_iam_policy_document" "budget_topic" {
  statement {
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.budget.arn]
    principals {
      type        = "Service"
      identifiers = ["budgets.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account]
    }
  }
}

resource "aws_sns_topic_policy" "budget" {
  arn    = aws_sns_topic.budget.arn
  policy = data.aws_iam_policy_document.budget_topic.json
}

# ---------- Lambda ①③ ----------
locals {
  lambdas = {
    dispatch = {
      env    = { GITHUB_TOKEN_SECRET = aws_secretsmanager_secret.github_dispatch.arn, GITHUB_REPO = var.github_repo, GITHUB_REF = var.github_ref }
      secret = aws_secretsmanager_secret.github_dispatch.arn
    }
    budget_guard = {
      env    = { STATE_MACHINE_ARN = "arn:aws:states:${var.region}:${local.account}:stateMachine:${local.name}-power" }
      secret = null
    }
  }
}

data "archive_file" "lambda" {
  for_each    = local.lambdas
  type        = "zip"
  source_file = "${path.module}/lambda/${each.key}.py"
  output_path = "${path.module}/.build/${each.key}.zip"
}

data "aws_iam_policy_document" "lambda_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  for_each           = local.lambdas
  name               = "${local.name}-lambda-${replace(each.key, "_", "-")}"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
}

resource "aws_iam_role_policy_attachment" "lambda_logs" {
  for_each   = local.lambdas
  role       = aws_iam_role.lambda[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda" {
  for_each = local.lambdas
  name     = "access"
  role     = aws_iam_role.lambda[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = each.value.secret != null ? [
      { Effect = "Allow", Action = "secretsmanager:GetSecretValue", Resource = each.value.secret }
      ] : [
      { Effect = "Allow", Action = "states:StartExecution", Resource = each.value.env.STATE_MACHINE_ARN }
    ]
  })
}

resource "aws_lambda_function" "this" {
  for_each         = local.lambdas
  function_name    = "${local.name}-${replace(each.key, "_", "-")}"
  role             = aws_iam_role.lambda[each.key].arn
  runtime          = "python3.13"
  handler          = "${each.key}.handler"
  filename         = data.archive_file.lambda[each.key].output_path
  source_code_hash = data.archive_file.lambda[each.key].output_base64sha256
  timeout          = 30
  environment { variables = each.value.env }
}

resource "aws_cloudwatch_log_group" "lambda" {
  for_each          = local.lambdas
  name              = "/aws/lambda/${aws_lambda_function.this[each.key].function_name}"
  retention_in_days = 14
}

resource "aws_sns_topic_subscription" "budget_guard" {
  topic_arn = aws_sns_topic.budget.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.this["budget_guard"].arn
}

resource "aws_lambda_permission" "budget_guard" {
  statement_id  = "sns-budget"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.this["budget_guard"].function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.budget.arn
}

# ---------- Step Functions (켜기·끄기 순서 · 대기 · 재시도 · 결과 알림) ----------
data "aws_iam_policy_document" "sfn_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "sfn" {
  name               = "${local.name}-sfn-power"
  assume_role_policy = data.aws_iam_policy_document.sfn_trust.json
}

resource "aws_iam_role_policy" "sfn" {
  name = "access"
  role = aws_iam_role.sfn.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = "lambda:InvokeFunction", Resource = aws_lambda_function.this["dispatch"].arn },
      { Effect = "Allow", Action = "sns:Publish", Resource = aws_sns_topic.alerts.arn },
    ]
  })
}

resource "aws_sfn_state_machine" "power" {
  name     = "${local.name}-power"
  role_arn = aws_iam_role.sfn.arn
  definition = jsonencode({
    Comment = "AWS 켜기·끄기 — GitHub Actions 실행 후 작업 토큰으로 결과를 기다림"
    StartAt = "RunWorkflow"
    States = {
      RunWorkflow = {
        Type           = "Task"
        Resource       = "arn:aws:states:::lambda:invoke.waitForTaskToken"
        Parameters     = { FunctionName = aws_lambda_function.this["dispatch"].arn, Payload = { "action.$" = "$.action", "token.$" = "$$.Task.Token" } }
        TimeoutSeconds = 7200 # 켜기 약 30분 · 끄기 약 20분, 워크플로 timeout 120분
        ResultPath     = "$.result"
        Retry          = [{ ErrorEquals = ["Lambda.ServiceException", "Lambda.TooManyRequestsException", "Lambda.Unknown"], MaxAttempts = 2, IntervalSeconds = 30 }]
        Catch          = [{ ErrorEquals = ["States.ALL"], ResultPath = "$.error", Next = "NotifyFailure" }]
        Next           = "NotifySuccess"
      }
      NotifySuccess = {
        Type       = "Task"
        Resource   = "arn:aws:states:::sns:publish"
        Parameters = { TopicArn = aws_sns_topic.alerts.arn, Subject = "AWS 켜기·끄기", "Message.$" = "States.Format('{} 성공', $.action)" }
        End        = true
      }
      NotifyFailure = {
        Type       = "Task"
        Resource   = "arn:aws:states:::sns:publish"
        Parameters = { TopicArn = aws_sns_topic.alerts.arn, Subject = "AWS 켜기·끄기 실패", "Message.$" = "States.Format('{} 실패: {}', $.action, $.error.Error)" }
        Next       = "Failed"
      }
      Failed = { Type = "Fail" }
    }
  })
}

# ---------- EventBridge Scheduler (평일 09:00 켜기 · 19:00 끄기, 공휴일은 막지 않음) ----------
data "aws_iam_policy_document" "scheduler_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "scheduler" {
  name               = "${local.name}-scheduler-power"
  assume_role_policy = data.aws_iam_policy_document.scheduler_trust.json
}

resource "aws_iam_role_policy" "scheduler" {
  name = "start"
  role = aws_iam_role.scheduler.id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "states:StartExecution", Resource = aws_sfn_state_machine.power.arn }]
  })
}

resource "aws_scheduler_schedule" "power" {
  for_each                     = { up = var.schedule_up, down = var.schedule_down }
  name                         = "${local.name}-${each.key}"
  schedule_expression          = each.value
  schedule_expression_timezone = "Asia/Seoul"
  flexible_time_window { mode = "OFF" }
  target {
    arn      = aws_sfn_state_machine.power.arn
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({ action = each.key })
  }
}

# ---------- Budgets (일일 비용) ----------
resource "aws_budgets_budget" "daily" {
  name         = "${local.name}-daily"
  budget_type  = "COST"
  limit_amount = tostring(var.budget_daily_usd)
  limit_unit   = "USD"
  time_unit    = "DAILY"

  # 80% 는 메일만 (수신자가 있을 때)
  dynamic "notification" {
    for_each = length(var.alert_emails) > 0 ? [1] : []
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = 80
      threshold_type             = "PERCENTAGE"
      notification_type          = "ACTUAL"
      subscriber_email_addresses = var.alert_emails
    }
  }

  # 넘으면 끄기
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = var.alert_emails
    subscriber_sns_topic_arns  = [aws_sns_topic.budget.arn]
  }
}
