# ---------- 운영자 전용 Cognito 풀 (Grafana SSO) — 고객 풀(cognito.tf)과 완전히 분리 ----------
#   로그인은 이메일, 계정은 관리자만 생성 (scripts/aws/ops-users.sh) · 권한은 그룹 → Grafana 역할
#   ALB 가 먼저 인증(앱 클라이언트 alb)하고 Grafana 도 같은 풀로 로그인(앱 클라이언트 grafana) → 사용자는 Hosted UI 에서 한 번만 로그인
#   메일은 Cognito 기본 발송 — 초대 메일(임시 비밀번호)만 나감
locals {
  ops_domain_prefix = coalesce(var.ops_cognito_domain_prefix, "${var.project}-ops")
  ops_hosted_ui     = "https://${local.ops_domain_prefix}.auth.${var.region}.amazoncognito.com"
  ops_groups        = ["grafana-admin", "grafana-viewer"]
  grafana_login_url = "https://${var.domain_name}/grafana/login"
  ops_clients = {
    alb     = { callback = ["https://${var.domain_name}/oauth2/idpresponse"] }
    grafana = { callback = ["${local.grafana_login_url}/generic_oauth"] }
  }
}

resource "aws_cognito_user_pool" "ops" {
  name = "${local.name}-ops"
  # 기본 클레임(cognito:groups · email)만 써서 고객 풀과 같은 LITE
  user_pool_tier = "LITE"

  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]
  deletion_protection      = "ACTIVE"
  mfa_configuration        = "OPTIONAL"

  software_token_mfa_configuration {
    enabled = true
  }

  username_configuration {
    case_sensitive = false
  }

  admin_create_user_config {
    allow_admin_create_user_only = true
  }

  # Grafana 가 이메일로 기존 계정을 연결하므로(oauth_allow_insecure_email_lookup) 사용자가 이메일을 못 바꾸게 함
  schema {
    name                = "email"
    attribute_data_type = "String"
    mutable             = false
    required            = true
    string_attribute_constraints {
      min_length = 5
      max_length = 254
    }
  }

  password_policy {
    minimum_length                   = 12
    require_lowercase                = true
    require_numbers                  = true
    require_symbols                  = true
    require_uppercase                = true
    temporary_password_validity_days = 7
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }
}

resource "aws_cognito_user_group" "ops" {
  for_each     = toset(local.ops_groups)
  user_pool_id = aws_cognito_user_pool.ops.id
  name         = each.value
}

resource "aws_cognito_user_pool_domain" "ops" {
  domain       = local.ops_domain_prefix
  user_pool_id = aws_cognito_user_pool.ops.id
}

resource "aws_cognito_user_pool_client" "ops" {
  for_each     = local.ops_clients
  name         = "${local.name}-ops-${each.key}"
  user_pool_id = aws_cognito_user_pool.ops.id

  generate_secret                      = true
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email", "profile"]
  supported_identity_providers         = ["COGNITO"]
  callback_urls                        = each.value.callback
  logout_urls                          = [local.grafana_login_url]

  explicit_auth_flows           = ["ALLOW_USER_SRP_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"]
  prevent_user_existence_errors = "ENABLED"
  enable_token_revocation       = true
}

# Grafana 앱 클라이언트 비밀값 — ESO 가 monitoring 으로 주입, 키 이름 = GF_* 환경 변수 (addons.sh). ALB 규칙은 비밀값 없이 풀에서 직접 읽어서 저장하지 않음
resource "aws_secretsmanager_secret" "ops_cognito_grafana" {
  name                    = "${local.secret_prefix}/ops-cognito-grafana"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "ops_cognito_grafana" {
  secret_id = aws_secretsmanager_secret.ops_cognito_grafana.id
  secret_string = jsonencode({
    GF_AUTH_GENERIC_OAUTH_CLIENT_ID     = aws_cognito_user_pool_client.ops["grafana"].id
    GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET = aws_cognito_user_pool_client.ops["grafana"].client_secret
  })
}

# ops-users.sh · addons.sh 가 읽음
resource "aws_ssm_parameter" "ops_cognito" {
  for_each = {
    ops_cognito_user_pool_id      = aws_cognito_user_pool.ops.id
    ops_cognito_alb_client_id     = aws_cognito_user_pool_client.ops["alb"].id
    ops_cognito_grafana_client_id = aws_cognito_user_pool_client.ops["grafana"].id
    ops_cognito_hosted_ui         = local.ops_hosted_ui
    grafana_root_url              = "https://${var.domain_name}/grafana/"
    grafana_signout_url           = "${local.ops_hosted_ui}/logout?client_id=${aws_cognito_user_pool_client.ops["grafana"].id}&logout_uri=${urlencode(local.grafana_login_url)}"
  }
  name  = "${local.ssm_prefix}/${each.key}"
  type  = "String"
  value = each.value
}
