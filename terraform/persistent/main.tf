# =============================================================================
# persistent — 매일 destroy 하지 않는 스택
#   ECR · Secrets Manager(비밀값·DB 마스터 비밀번호) · CloudWatch 로그 그룹 · RDS 파라미터 그룹
#   (Route 53 존 · ACM · CloudFront · Cognito · SES · 운영 자동화는 다음 단계에서 추가)
# =============================================================================
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 6.0" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
  }
  # backend 블록은 변수를 못 씀 → bucket·region 은 init 때 -backend-config 로 넘김
  #   terraform init -backend-config="bucket=$TF_STATE_BUCKET" -backend-config="region=$AWS_REGION"
  backend "s3" {
    key          = "persistent/terraform.tfstate"
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = { Project = var.project, Env = var.env, Stack = "persistent", ManagedBy = "terraform" }
  }
}

locals {
  name     = "${var.project}-${var.env}" # 리소스 이름 규칙 (ephemeral·스크립트·워크플로 동일)
  services = ["gateway", "member", "store", "order", "payment", "delivery"]

  # 서비스별 DB 계정 (helm/values/services/*.yaml 의 db.user 와 같아야 함)
  db_users = {
    member   = "member_svc"
    store    = "store_svc"
    order    = "order_svc"
    payment  = "payment_svc"
    delivery = "delivery_svc"
  }
  redis_services = ["gateway", "member"] # REDIS_SESSION_PASSWORD
  jwt_services   = ["gateway", "member"] # JWT_SECRET (Cognito 전환 전까지 앱이 요구)
  mq_username    = var.project
  db_master_user = "${replace(var.project, "-", "_")}_admin"

  secret_prefix  = coalesce(var.secret_prefix, "${var.project}/${var.env}")
  log_group_name = coalesce(var.log_group_name, "/${var.project}/${var.env}/containers")
}

# ---------- ECR <project>-<env>/<서비스> (설정은 기본값, 수명 주기는 이후 결정) ----------
resource "aws_ecr_repository" "svc" {
  for_each = toset(local.services)
  name     = "${local.name}/${each.key}"
}

# ---------- 비밀값 ----------
resource "random_password" "db_master" {
  length  = 32
  special = false
}

resource "random_password" "db_svc" {
  for_each = local.db_users
  length   = 32
  special  = false
}

# Amazon MQ: 12자 이상, 쉼표·콜론·등호 불가
resource "random_password" "mq" {
  length  = 32
  special = false
}

# ElastiCache AUTH 토큰: 16~128자, @ " / 불가
resource "random_password" "redis" {
  length  = 48
  special = false
}

resource "random_password" "jwt" {
  length  = 64
  special = false
}

# 인프라용 (terraform ephemeral 스택·DB 초기화 Job 이 읽음)
resource "aws_secretsmanager_secret" "infra" {
  name                    = "${local.secret_prefix}/infra"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "infra" {
  secret_id = aws_secretsmanager_secret.infra.id
  secret_string = jsonencode(merge(
    {
      DB_MASTER_USER     = local.db_master_user
      DB_MASTER_PASSWORD = random_password.db_master.result
      MQ_USER            = local.mq_username
      MQ_PASSWORD        = random_password.mq.result
      REDIS_AUTH_TOKEN   = random_password.redis.result
    },
    { for k, u in local.db_users : "DB_PASSWORD_${upper(k)}" => random_password.db_svc[k].result }
  ))
}

# 서비스별 (ESO 가 <prefix>/<서비스> 를 같은 이름의 K8s Secret 으로 만듦 — chart externalsecret.yaml)
resource "aws_secretsmanager_secret" "svc" {
  for_each                = toset(local.services)
  name                    = "${local.secret_prefix}/${each.key}"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "svc" {
  for_each  = toset(local.services)
  secret_id = aws_secretsmanager_secret.svc[each.key].id
  secret_string = jsonencode(merge(
    { RABBITMQ_USER = local.mq_username, RABBITMQ_PASSWORD = random_password.mq.result },
    contains(keys(local.db_users), each.key) ? { DB_PASSWORD = random_password.db_svc[each.key].result } : {},
    contains(local.redis_services, each.key) ? { REDIS_SESSION_PASSWORD = random_password.redis.result } : {},
    contains(local.jwt_services, each.key) ? { JWT_SECRET = random_password.jwt.result } : {},
    each.key == "payment" ? { TOSS_SECRET_KEY = "CHANGE_ME_toss_test_secret_key" } : {}
  ))
  # 토스 키 등 콘솔에서 바꾼 값을 다음 apply 가 덮어쓰지 않게
  lifecycle { ignore_changes = [secret_string] }
}

# ---------- CloudWatch Logs (Fluent Bit 목적지, 14일) ----------
resource "aws_cloudwatch_log_group" "containers" {
  name              = local.log_group_name
  retention_in_days = 14
}

# ---------- RDS 파라미터 그룹 (KST · 슬로우 쿼리 1초 · pg_stat_statements) ----------
resource "aws_db_parameter_group" "pg16" {
  name   = "${local.name}-pg16"
  family = "postgres16"

  parameter {
    name  = "timezone"
    value = "Asia/Seoul"
  }
  parameter {
    name  = "log_min_duration_statement"
    value = "1000"
  }
  parameter {
    name         = "shared_preload_libraries"
    value        = "pg_stat_statements"
    apply_method = "pending-reboot"
  }
}

# ---------- outputs ----------
output "ecr_registry" {
  value = split("/", aws_ecr_repository.svc["gateway"].repository_url)[0]
}

output "infra_secret_arn" {
  value = aws_secretsmanager_secret.infra.arn
}

output "service_secret_arns" {
  value = { for k, s in aws_secretsmanager_secret.svc : k => s.arn }
}

output "db_master_user" {
  value = local.db_master_user
}

output "db_master_password" {
  value     = random_password.db_master.result
  sensitive = true
}

output "mq_user" {
  value = local.mq_username
}

output "mq_password" {
  value     = random_password.mq.result
  sensitive = true
}

output "redis_auth_token" {
  value     = random_password.redis.result
  sensitive = true
}

output "db_parameter_group" {
  value = aws_db_parameter_group.pg16.name
}

output "log_group_name" {
  value = aws_cloudwatch_log_group.containers.name
}
