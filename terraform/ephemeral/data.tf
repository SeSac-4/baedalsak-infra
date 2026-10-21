# ---------- RDS PostgreSQL 16 · db.t4g.small · Multi-AZ ----------
resource "aws_db_subnet_group" "this" {
  name       = local.name
  subnet_ids = module.vpc.database_subnets
}

resource "aws_db_instance" "this" {
  identifier     = local.name
  engine         = "postgres"
  engine_version = "16"
  instance_class = "db.t4g.small"

  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  multi_az               = true
  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  parameter_group_name   = local.p.db_parameter_group
  publicly_accessible    = false

  username = local.p.db_master_user
  password = local.p.db_master_password

  # 매일 destroy 시 최종 스냅샷 → 다음 apply 에서 복원 (자동 백업은 인스턴스와 함께 사라짐)
  snapshot_identifier       = var.db_snapshot_identifier
  skip_final_snapshot       = false
  final_snapshot_identifier = "${local.name}-final-${formatdate("YYYYMMDDhhmm", timestamp())}"
  backup_retention_period   = 1
  copy_tags_to_snapshot     = true
  deletion_protection       = false

  auto_minor_version_upgrade      = true
  apply_immediately               = true
  enabled_cloudwatch_logs_exports = ["postgresql"]

  lifecycle {
    ignore_changes = [final_snapshot_identifier, snapshot_identifier]
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

  user {
    username = local.p.mq_user
    password = local.p.mq_password
  }
}

# ---------- ElastiCache Valkey 9.1 · cache.t4g.micro 단일(azs[0]) · TLS + AUTH ----------
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

  apply_immediately = true
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
  }
}

resource "aws_ssm_parameter" "infra" {
  for_each = local.ssm_values
  name     = "${local.ssm_prefix}/${each.key}"
  type     = "String"
  value    = each.value
}
