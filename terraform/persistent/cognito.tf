# ---------- Cognito (사용자 풀 2개: prod · 로컬 개발) ----------
#   가입은 member 만 Admin API 로 (AdminCreateUser → AdminSetUserPassword → AdminAddUserToGroup), self sign-up 막힘
#   username = member_id · 로그인은 이메일(alias) · 역할 = 그룹 → access 토큰 기본 클레임(username, cognito:groups)만 사용
#   member 가 AdminInitiateAuth(ADMIN_USER_PASSWORD_AUTH) · RevokeToken 을 호출, gateway 는 JWKS 로 access 토큰 검증
#   메일은 v1 에서 Cognito 기본 발송(일 50통) — SES 프로덕션 승인 후 email_configuration 을 SES 로 바꿈
locals {
  user_pools  = { prod = local.name, local = "${var.project}-local" }
  user_groups = ["CUSTOMER", "OWNER", "RIDER"]
  # 로컬 풀 Admin API 를 쓸 개발자 IAM 사용자 (sesac-d1: member 담당, sesac-d5: 인프라)
  local_pool_devs = ["sesac-d1", "sesac-d5"]
}

resource "aws_cognito_user_pool" "this" {
  for_each = local.user_pools
  name     = each.value

  alias_attributes         = ["email"] # 바꾸면 풀 재생성 — 사용자 있으면 이전 필요
  auto_verified_attributes = ["email"]
  deletion_protection      = each.key == "prod" ? "ACTIVE" : "INACTIVE"

  admin_create_user_config {
    allow_admin_create_user_only = true
  }

  password_policy {
    minimum_length    = 8
    require_lowercase = true
    require_numbers   = true
    require_symbols   = false
    require_uppercase = false
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }
}

resource "aws_cognito_user_group" "this" {
  for_each     = { for p in setproduct(keys(local.user_pools), local.user_groups) : "${p[0]}-${p[1]}" => { pool = p[0], group = p[1] } }
  user_pool_id = aws_cognito_user_pool.this[each.value.pool].id
  name         = each.value.group
}

resource "aws_cognito_user_pool_client" "member" {
  for_each     = local.user_pools
  name         = "${each.value}-member"
  user_pool_id = aws_cognito_user_pool.this[each.key].id

  generate_secret               = false
  explicit_auth_flows           = ["ALLOW_ADMIN_USER_PASSWORD_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"]
  prevent_user_existence_errors = "ENABLED"
  enable_token_revocation       = true

  access_token_validity  = 30
  id_token_validity      = 30
  refresh_token_validity = 14
  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "days"
  }
}

# 로컬 풀 Admin API 권한 — AWS 배포는 develop 머지 커밋만 되므로 가입·로그인은 머지 전 로컬에서 확인
resource "aws_iam_user_policy" "local_pool" {
  for_each = toset(local.local_pool_devs)
  name     = "${var.project}-cognito-local-admin"
  user     = each.value
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "cognito-idp:AdminCreateUser",
        "cognito-idp:AdminSetUserPassword",
        "cognito-idp:AdminDeleteUser",
        "cognito-idp:AdminInitiateAuth",
        "cognito-idp:AdminAddUserToGroup",
      ]
      Resource = aws_cognito_user_pool.this["local"].arn
    }]
  })
}

# 앱이 ESO 로 읽을 값 (prod 풀만)
resource "aws_ssm_parameter" "cognito" {
  for_each = {
    cognito_user_pool_id = aws_cognito_user_pool.this["prod"].id
    cognito_client_id    = aws_cognito_user_pool_client.member["prod"].id
    cognito_issuer_uri   = "https://cognito-idp.${var.region}.amazonaws.com/${aws_cognito_user_pool.this["prod"].id}"
  }
  name  = "${local.ssm_prefix}/${each.key}"
  type  = "String"
  value = each.value
}
