# =============================================================================
# 운영 자동화 (그림 v6 B안)
#   켜기·끄기 : EventBridge Scheduler(평일 09:30·19:00 KST) → Step Functions → Lambda ① → GitHub Actions
#              워크플로가 작업 토큰으로 결과 보고 → Lambda ② 가 결과 확인 → SNS alerts → 메일
#              (확인: GitHub 실패 job·step·오류 로그 + AWS 실제 상태 — 켜기는 EKS·RDS·사이트, 끄기는 남은 리소스)
#   알람      : CloudWatch 알람(ephemeral/alarms.tf) → SNS alerts → 메일 (ALERT_EMAILS, 구독 확인 메일 1회 클릭)
#   예산      : Budgets(일일) $5 넘으면 메일(경고) · $10 넘으면 메일 + SNS budget → Lambda ③ → Step Functions(action=down)
#   비용 메일 : 매일 09:00 KST Scheduler → Lambda ④ cost_report → Cost Explorer(전날, 크레딧·환불 제외) → SES 메일(서비스별·스택 태그별)
#   값은 콘솔에서 넣음 (Terraform 은 빈 Secret 만 만듦):
#     <SECRET_PREFIX>/github-dispatch  GitHub fine-grained PAT (이 레포, Actions: Read and write)
#     <SECRET_PREFIX>/seed             {"SEED_PASSWORD": "..."} prod 풀 seed 사용자 비밀번호
# =============================================================================

resource "aws_secretsmanager_secret" "github_dispatch" {
  name                    = "${local.secret_prefix}/github-dispatch"
  recovery_window_in_days = 0
}

# prod 풀 seed 사용자 비밀번호 {"SEED_PASSWORD": "..."} — 값은 CLI·콘솔에서 넣음, seed 스크립트만 읽음
resource "aws_secretsmanager_secret" "seed" {
  name                    = "${local.secret_prefix}/seed"
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

# ---------- Lambda ① dispatch · ② report · ③ budget_guard · ④ cost_report ----------
locals {
  state_machine_arn = "arn:aws:states:${var.region}:${local.account}:stateMachine:${local.name}-power"
  github_env        = { GITHUB_TOKEN_SECRET = aws_secretsmanager_secret.github_dispatch.arn, GITHUB_REPO = var.github_repo, GITHUB_REF = var.github_ref }
  read_github_token = { Effect = "Allow", Action = "secretsmanager:GetSecretValue", Resource = aws_secretsmanager_secret.github_dispatch.arn }
  cost_sender       = coalesce(var.cost_report_sender, "cost-report@${var.domain_name}")
  lambdas = {
    dispatch = {
      env        = local.github_env
      timeout    = 30
      statements = [local.read_github_token]
    }
    report = {
      env     = merge(local.github_env, { NAME = local.name, TOPIC_ARN = aws_sns_topic.alerts.arn, DOMAIN_NAME = var.domain_name })
      timeout = 120
      statements = [
        local.read_github_token,
        { Effect = "Allow", Action = "sns:Publish", Resource = aws_sns_topic.alerts.arn },
        { # 상태 확인 (읽기 전용)
          Effect = "Allow", Resource = "*", Action = [
            "eks:ListClusters", "eks:DescribeCluster", "eks:ListNodegroups", "eks:DescribeNodegroup",
            "rds:DescribeDBInstances", "mq:ListBrokers", "elasticache:DescribeReplicationGroups",
            "elasticloadbalancing:DescribeLoadBalancers", "ec2:DescribeNatGateways", "ec2:DescribeInstances",
            "cloudfront:ListDistributions",
          ]
        },
      ]
    }
    budget_guard = {
      env        = { STATE_MACHINE_ARN = local.state_machine_arn }
      timeout    = 30
      statements = [{ Effect = "Allow", Action = "states:StartExecution", Resource = local.state_machine_arn }]
    }
    cost_report = {
      env     = { NAME = local.name, SENDER = local.cost_sender, RECIPIENTS = jsonencode(var.alert_emails), TAG_KEY = var.cost_tag_key }
      timeout = 60
      statements = [
        { Effect = "Allow", Action = "ce:GetCostAndUsage", Resource = "*" }, # Cost Explorer 는 리소스 단위 권한 없음
        # 샌드박스에서는 받는 주소 identity 에도 권한 필요 (없으면 AccessDenied — 10-28·29 미발송)
        { Effect = "Allow", Action = "ses:SendEmail", Resource = concat([aws_sesv2_email_identity.domain.arn], [for r in aws_sesv2_email_identity.recipient : r.arn]) },
      ]
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
  policy   = jsonencode({ Version = "2012-10-17", Statement = each.value.statements })
}

resource "aws_lambda_function" "this" {
  for_each         = local.lambdas
  function_name    = "${local.name}-${replace(each.key, "_", "-")}"
  role             = aws_iam_role.lambda[each.key].arn
  runtime          = "python3.13"
  handler          = "${each.key}.handler"
  filename         = data.archive_file.lambda[each.key].output_path
  source_code_hash = data.archive_file.lambda[each.key].output_base64sha256
  timeout          = each.value.timeout
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

# ---------- Step Functions (켜기·끄기 실행 · 대기 · 재시도 · 결과 확인 · 메일) ----------
#   RunWorkflow(Lambda ①, 작업 토큰 대기 · 워크플로 실패 시 1회 재실행) ─ 성공/실패/시간 초과 모두 → Report(Lambda ②: 로그·상태 확인 → 메일) → ok 면 성공, 아니면 실패
#   Report 자체가 실패하면 → NotifyFallback(SNS 직접) → 실패
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
      { Effect = "Allow", Action = "lambda:InvokeFunction", Resource = [aws_lambda_function.this["dispatch"].arn, aws_lambda_function.this["report"].arn] },
      { Effect = "Allow", Action = "sns:Publish", Resource = aws_sns_topic.alerts.arn },
    ]
  })
}

resource "aws_sfn_state_machine" "power" {
  name     = "${local.name}-power"
  role_arn = aws_iam_role.sfn.arn
  definition = jsonencode({
    Comment = "AWS 켜기·끄기 — GitHub Actions 실행 후 작업 토큰으로 결과를 기다리고, 결과·로그·AWS 상태를 메일로 보냄"
    StartAt = "RunWorkflow"
    States = {
      RunWorkflow = {
        Type           = "Task"
        Resource       = "arn:aws:states:::lambda:invoke.waitForTaskToken"
        Parameters     = { FunctionName = aws_lambda_function.this["dispatch"].arn, Payload = { "action.$" = "$.action", "token.$" = "$$.Task.Token" } }
        TimeoutSeconds = 7200 # 켜기 약 30분 · 끄기 약 20분, 워크플로 timeout 120분
        ResultPath     = "$.result"
        Retry = [
          { ErrorEquals = ["Lambda.ServiceException", "Lambda.TooManyRequestsException", "Lambda.Unknown"], MaxAttempts = 2, IntervalSeconds = 30 },
          # 워크플로 실패(terraform·helm 일시 오류 등) → 1회 다시 실행. apply·destroy 는 다시 돌려도 안전. 시간 초과·취소는 재시도 안 함
          { ErrorEquals = ["WorkflowFailure"], MaxAttempts = 1, IntervalSeconds = 120 },
        ]
        Catch = [{ ErrorEquals = ["States.ALL"], ResultPath = "$.error", Next = "Report" }]
        Next  = "Report"
      }
      Report = {
        Type           = "Task"
        Resource       = "arn:aws:states:::lambda:invoke"
        Parameters     = { FunctionName = aws_lambda_function.this["report"].arn, Payload = { "input.$" = "$", "started.$" = "$$.Execution.StartTime" } }
        ResultSelector = { "ok.$" = "$.Payload.ok" }
        ResultPath     = "$.report"
        Retry          = [{ ErrorEquals = ["Lambda.ServiceException", "Lambda.TooManyRequestsException", "Lambda.Unknown"], MaxAttempts = 2, IntervalSeconds = 10 }]
        Catch          = [{ ErrorEquals = ["States.ALL"], ResultPath = "$.reportError", Next = "NotifyFallback" }]
        Next           = "Result"
      }
      Result = {
        Type    = "Choice"
        Choices = [{ Variable = "$.report.ok", BooleanEquals = true, Next = "Done" }]
        Default = "Failed"
      }
      # SNS 메일 제목은 ASCII 만 허용
      NotifyFallback = {
        Type       = "Task"
        Resource   = "arn:aws:states:::sns:publish"
        Parameters = { TopicArn = aws_sns_topic.alerts.arn, Subject = "[${local.name}] AWS power FAILED (report error)", "Message.$" = "States.Format('AWS {} - 결과 확인 Lambda 실패. Step Functions 실행 기록을 확인하세요. {}', $.action, States.JsonToString($.reportError))" }
        Next       = "Failed"
      }
      Done   = { Type = "Succeed" }
      Failed = { Type = "Fail" }
    }
  })
}

# ---------- EventBridge Scheduler (평일 09:30 켜기 · 19:00 끄기, 공휴일은 막지 않음) ----------
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

  # 경고: 메일만 (수신자가 있을 때)
  dynamic "notification" {
    for_each = length(var.alert_emails) > 0 ? [1] : []
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = var.budget_warn_usd
      threshold_type             = "ABSOLUTE_VALUE"
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

# ---------- 일일 비용 메일 (매일 09:00 KST → Lambda ④) ----------
resource "aws_iam_role" "scheduler_cost" {
  name               = "${local.name}-scheduler-cost"
  assume_role_policy = data.aws_iam_policy_document.scheduler_trust.json
}

resource "aws_iam_role_policy" "scheduler_cost" {
  name = "invoke"
  role = aws_iam_role.scheduler_cost.id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "lambda:InvokeFunction", Resource = aws_lambda_function.this["cost_report"].arn }]
  })
}

resource "aws_scheduler_schedule" "cost_report" {
  name                         = "${local.name}-cost-report"
  schedule_expression          = var.schedule_cost_report
  schedule_expression_timezone = "Asia/Seoul"
  flexible_time_window { mode = "OFF" }
  target {
    arn      = aws_lambda_function.this["cost_report"].arn
    role_arn = aws_iam_role.scheduler_cost.arn
  }
}
