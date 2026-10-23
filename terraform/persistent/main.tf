# =============================================================================
# persistent — 매일 destroy 하지 않는 스택
#   ECR · Secrets Manager(비밀값·DB 마스터 비밀번호) · CloudWatch 로그 그룹 · RDS 파라미터 그룹
#   dns.tf      Route 53 존(도메인 구매 시 자동 생성 → 참조) · ACM ①(us-east-1) ②(서울)
#   frontend.tf S3 프론트 · OAC · CF Function   (CloudFront 배포 자체는 ALB 와 함께 ephemeral/edge.tf)
#   cognito.tf · ses.tf · audit.tf(CloudTrail · 로그 버킷) · ops.tf(알람 토픽 → 메일 · 켜기/끄기 자동화 · Budgets)
# =============================================================================
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws     = { source = "hashicorp/aws", version = "~> 6.0" }
    random  = { source = "hashicorp/random", version = "~> 3.6" }
    archive = { source = "hashicorp/archive", version = "~> 2.7" }
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

# CloudFront 인증서(ACM ①)는 us-east-1 에만 만들 수 있음
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
  default_tags {
    tags = { Project = var.project, Env = var.env, Stack = "persistent", ManagedBy = "terraform" }
  }
}

data "aws_caller_identity" "this" {}

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
  ssm_prefix     = coalesce(var.ssm_prefix, "/${var.project}/${var.env}")
  account        = data.aws_caller_identity.this.account_id
}

# ---------- ECR <project>-<env>/<서비스> · 최신 7개만 보관 (롤백용 이전 버전 포함) ----------
resource "aws_ecr_repository" "svc" {
  for_each = toset(local.services)
  name     = "${local.name}/${each.key}"

  # push 할 때 기본 취약점 스캔 (무료) — ECR 경로에는 테스트·Trivy 가 없어서 최소한의 확인
  image_scanning_configuration { scan_on_push = true }
}

resource "aws_ecr_lifecycle_policy" "svc" {
  for_each   = aws_ecr_repository.svc
  repository = each.value.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "keep last 7 images"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 7 }
      action       = { type = "expire" }
    }]
  })
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

# ---------- ephemeral 이 쓰는 값 (dns · frontend · audit · ops) ----------
output "domain_name" {
  value = var.domain_name
}

output "zone_id" {
  value = data.aws_route53_zone.main.zone_id
}

output "cloudfront_certificate_arn" {
  value = aws_acm_certificate_validation.cloudfront.certificate_arn
}

output "alb_certificate_arn" {
  value = aws_acm_certificate_validation.alb.certificate_arn
}

output "front_bucket" {
  value = aws_s3_bucket.front.bucket
}

output "front_bucket_arn" {
  value = aws_s3_bucket.front.arn
}

output "front_bucket_domain" {
  value = aws_s3_bucket.front.bucket_regional_domain_name
}

output "front_oac_id" {
  value = aws_cloudfront_origin_access_control.front.id
}

output "spa_function_arn" {
  value = aws_cloudfront_function.spa.arn
}

output "logs_bucket" {
  value = aws_s3_bucket.logs.bucket
}

output "alerts_topic_arn" {
  value = aws_sns_topic.alerts.arn
}
