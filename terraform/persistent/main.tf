# =============================================================================
# persistent — 매일 destroy 하지 않는 스택
#   ECR · Secrets Manager(비밀값·DB 마스터 비밀번호) · Loki 로그 버킷 · RDS 파라미터 그룹
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
  jwt_services   = []                    # JWT_SECRET — Cognito 전환으로 미사용 (member server #82, gateway helm 주입 제거). 기존 시크릿 값은 ignore_changes 로 남음
  mq_username    = var.project
  db_master_user = "${replace(var.project, "-", "_")}_admin"

  secret_prefix = coalesce(var.secret_prefix, "${var.project}/${var.env}")
  ssm_prefix    = coalesce(var.ssm_prefix, "/${var.project}/${var.env}")
  account       = data.aws_caller_identity.this.account_id
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

# Grafana admin (monitoring 의 ExternalSecret grafana-admin 이 읽음 — addons.sh)
resource "random_password" "grafana" {
  length  = 24
  special = false
}

resource "aws_secretsmanager_secret" "grafana" {
  name                    = "${local.secret_prefix}/grafana"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "grafana" {
  secret_id     = aws_secretsmanager_secret.grafana.id
  secret_string = jsonencode({ "admin-user" = "admin", "admin-password" = random_password.grafana.result })
}

# ---------- Loki 저장소 (앱 로그, Fluent Bit → Loki → S3) — 클러스터를 매일 지워도 로그는 남음 ----------
resource "aws_s3_bucket" "loki" {
  bucket        = "${local.name}-loki-${local.account}"
  force_destroy = true # 로그 객체가 있어도 persistent 정리 시 함께 삭제
}

resource "aws_s3_bucket_public_access_block" "loki" {
  bucket                  = aws_s3_bucket.loki.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "loki" {
  bucket = aws_s3_bucket.loki.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

# 보관은 Loki compactor 가 14일(336h)로 지움 — 클러스터가 꺼져 compactor 가 못 돈 날 대비 하루 여유
resource "aws_s3_bucket_lifecycle_configuration" "loki" {
  bucket = aws_s3_bucket.loki.id
  rule {
    id     = "expire-15d"
    status = "Enabled"
    filter {}
    expiration { days = 15 }
  }
}

# addons.sh 가 읽음 (Loki 차트 bucketNames)
resource "aws_ssm_parameter" "loki_bucket" {
  name  = "${local.ssm_prefix}/loki_bucket"
  type  = "String"
  value = aws_s3_bucket.loki.bucket
}

# ---------- Tempo 저장소 (추적, 앱 OTLP → Tempo → S3) — Loki 와 같은 구성 ----------
resource "aws_s3_bucket" "tempo" {
  bucket        = "${local.name}-tempo-${local.account}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "tempo" {
  bucket                  = aws_s3_bucket.tempo.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tempo" {
  bucket = aws_s3_bucket.tempo.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

# 보관은 Tempo compactor 가 14일(336h)로 지움 — 하루 여유는 Loki 와 같은 이유
resource "aws_s3_bucket_lifecycle_configuration" "tempo" {
  bucket = aws_s3_bucket.tempo.id
  rule {
    id     = "expire-15d"
    status = "Enabled"
    filter {}
    expiration { days = 15 }
  }
}

# addons.sh 가 읽음 (Tempo 차트 storage.trace.s3.bucket)
resource "aws_ssm_parameter" "tempo_bucket" {
  name  = "${local.ssm_prefix}/tempo_bucket"
  type  = "String"
  value = aws_s3_bucket.tempo.bucket
}

# ---------- 토스 클라이언트 키 (프론트 빌드 VITE_TOSS_CLIENT_KEY, frontend.yml 이 읽음) ----------
#   브라우저에 노출되는 공개 키라 String. 시크릿 키(Secrets Manager <SECRET_PREFIX>/payment)와 같은 토스 계정의 짝으로 맞출 것
#   기본값은 토스 문서용 테스트 키 — 콘솔에서 바꾼 값을 다음 apply 가 덮어쓰지 않게
resource "aws_ssm_parameter" "toss_client_key" {
  name  = "${local.ssm_prefix}/toss_client_key"
  type  = "String"
  value = "test_gck_docs_Ovk5rk1EwkEbP0W43n07xlzm"
  lifecycle { ignore_changes = [value] }
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

output "loki_bucket_arn" {
  value = aws_s3_bucket.loki.arn
}

output "tempo_bucket_arn" {
  value = aws_s3_bucket.tempo.arn
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
