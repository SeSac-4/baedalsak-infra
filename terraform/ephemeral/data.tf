# ---------- RDS PostgreSQL 16 · db.t4g.micro · Multi-AZ (#45) · 운영: 끌 때 스냅샷 → 켤 때 복원 ----------
#   끄기 워크플로가 destroy 직전에 스냅샷을 직접 만들고 완료를 확인 (aws-stack.yml, 실패하면 destroy 안 함)
#   → 다음 켜기(apply)가 최신 스냅샷으로 복원 — 데이터 유지
#   db-init(DB·계정)·Flyway 는 멱등이라 복원한 DB 에 다시 돌아도 그대로
resource "aws_db_subnet_group" "this" {
  name       = local.name
  subnet_ids = module.vpc.database_subnets
}

resource "aws_db_instance" "this" {
  identifier     = local.name
  engine         = "postgres"
  engine_version = "16"
  instance_class = "db.t4g.micro" # 개발 기간 최소 사양 (이슈 있으면 올림)
  # instance_class = "db.t4g.small" # 이전 값

  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  multi_az               = true # 운영 (설계: 유일하게 이중화, 장애 시 1~2분 자동 전환, #45)
  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  parameter_group_name   = local.p.db_parameter_group
  publicly_accessible    = false

  username = local.p.db_master_user
  password = local.p.db_master_password

  # 스냅샷은 끄기 워크플로가 destroy 전에 만듦 → destroy 자체의 최종 스냅샷은 끔 (떠 있는 인스턴스에도 바로 적용되게)
  #   자동 백업은 destroy 때 함께 지워져 의미 없음 → 0. 스냅샷은 최신 7개 보관
  snapshot_identifier     = var.db_snapshot_identifier
  skip_final_snapshot     = true
  backup_retention_period = 0
  copy_tags_to_snapshot   = true
  deletion_protection     = false

  auto_minor_version_upgrade      = true
  apply_immediately               = true
  enabled_cloudwatch_logs_exports = ["postgresql"]

  lifecycle {
    ignore_changes = [final_snapshot_identifier, snapshot_identifier] # 운영 스냅샷 방식으로 되돌릴 때 필요
  }
}

# ---------- Amazon MQ RabbitMQ 4.2 · mq.m7g.medium 단일(azs[0]) ----------
resource "aws_mq_broker" "this" {
  broker_name        = local.name
  engine_type        = "RabbitMQ"
  engine_version     = "4.2"
  host_instance_type = "mq.m7g.medium"
  deployment_mode    = "SINGLE_INSTANCE"

  publicly_accessible        = false
  subnet_ids                 = [module.vpc.database_subnets[0]]
  security_groups            = [aws_security_group.mq.id]
  auto_minor_version_upgrade = true
  apply_immediately          = true

  # 일반 로그 → CloudWatch /aws/amazonmq/broker/<브로커 ID>/general (보존 14일 · S3 내보내기는 persistent Lambda ⑥)
  logs {
    general = true
  }

  user {
    username = local.p.mq_user
    password = local.p.mq_password
  }
}

# ---------- ElastiCache Valkey 9.1 · cache.t4g.micro 단일(azs[0]) · TLS + AUTH ----------
#   운영: 끌 때 스냅샷(aws-stack.yml, destroy 전) → 켤 때 복원 — refresh 세션 · 블랙리스트 유지 (매일 강제 로그아웃 없음)
resource "aws_elasticache_subnet_group" "this" {
  name       = local.name
  subnet_ids = module.vpc.database_subnets
}

resource "aws_elasticache_parameter_group" "valkey9" {
  name   = "${local.name}-valkey9"
  family = "valkey9"

  parameter {
    name  = "maxmemory-policy"
    value = "noeviction"
  }
}

resource "aws_elasticache_replication_group" "this" {
  replication_group_id = local.name
  description          = "${local.name} refresh session, blacklist, ratelimiter"
  engine               = "valkey"
  engine_version       = "9.1"
  node_type            = "cache.t4g.micro"
  num_cache_clusters   = 1
  port                 = 6379

  subnet_group_name    = aws_elasticache_subnet_group.this.name
  security_group_ids   = [aws_security_group.redis.id]
  parameter_group_name = aws_elasticache_parameter_group.valkey9.name

  preferred_cache_cluster_azs = [local.azs[0]]
  automatic_failover_enabled  = false
  multi_az_enabled            = false

  transit_encryption_enabled = true
  at_rest_encryption_enabled = true
  auth_token                 = local.p.redis_auth_token

  snapshot_name = var.redis_snapshot_name

  apply_immediately = true

  lifecycle {
    ignore_changes = [snapshot_name] # 복원은 생성할 때만 — 다음 apply 에서 값이 달라도 다시 만들지 않음
  }
}

# ---------- Parameter Store (인프라가 만든 값) ----------
locals {
  mq_endpoint = aws_mq_broker.this.instances[0].endpoints[0] # amqps://b-xxxx.mq.<region>.on.aws:5671
  mq_host     = regex("^amqps://([^:]+)", local.mq_endpoint)[0]
  ssm_values = {
    rds_host         = aws_db_instance.this.address
    mq_host          = local.mq_host
    mq_console_url   = aws_mq_broker.this.instances[0].console_url
    redis_host       = aws_elasticache_replication_group.this.primary_endpoint_address
    target_group_arn = aws_lb_target_group.gateway.arn
    alb_dns          = aws_lb.internal.dns_name
    cloudfront_id    = aws_cloudfront_distribution.main.id
    # addons.sh 의 Grafana · Argo CD TargetGroupBinding · NetworkPolicy
    grafana_target_group_arn = aws_lb_target_group.grafana.arn
    argocd_target_group_arn  = aws_lb_target_group.argocd.arn
    alb_subnet_cidrs         = join(",", local.alb_subnet_cidrs)
  }
}

resource "aws_ssm_parameter" "infra" {
  for_each = local.ssm_values
  name     = "${local.ssm_prefix}/${each.key}"
  type     = "String"
  value    = each.value
}
