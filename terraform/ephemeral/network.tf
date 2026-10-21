# VPC 10.0.0.0/16 — public /24 ×2 · EKS private /20 ×2 · data /24 ×2, NAT 1개(azs[0])
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = local.name
  cidr = "10.0.0.0/16"
  azs  = local.azs

  public_subnets   = ["10.0.0.0/24", "10.0.1.0/24"]
  private_subnets  = ["10.0.32.0/20", "10.0.48.0/20"]
  database_subnets = ["10.0.64.0/24", "10.0.65.0/24"]

  create_database_subnet_group       = false
  create_database_subnet_route_table = true # data 서브넷은 인터넷 경로 없음

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true
  enable_dns_support   = true

  public_subnet_suffix   = "public"
  private_subnet_suffix  = "eks"
  database_subnet_suffix = "data"
}

# ---------- 보안그룹 ----------
# internal ALB: 지금은 VPC 안에서만 (CloudFront VPC origin 연결 시 그 SG 로 좁힘)
resource "aws_security_group" "alb" {
  name        = "${local.name}-alb"
  description = "internal ALB"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "HTTP from VPC"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [module.vpc.vpc_cidr_block]
  }
  ingress {
    description = "HTTPS from VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [module.vpc.vpc_cidr_block]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Bastion: 인바운드 없음 (SSM 접속)
resource "aws_security_group" "bastion" {
  name        = "${local.name}-bastion"
  description = "bastion (SSM only)"
  vpc_id      = module.vpc.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "rds" {
  name        = "${local.name}-rds"
  description = "RDS PostgreSQL"
  vpc_id      = module.vpc.vpc_id
}

resource "aws_security_group" "mq" {
  name        = "${local.name}-mq"
  description = "Amazon MQ"
  vpc_id      = module.vpc.vpc_id
}

resource "aws_security_group" "redis" {
  name        = "${local.name}-redis"
  description = "ElastiCache Valkey"
  vpc_id      = module.vpc.vpc_id
}

locals {
  data_ingress = {
    rds_node     = { sg = aws_security_group.rds.id, port = 5432, src = module.eks.node_security_group_id }
    rds_bastion  = { sg = aws_security_group.rds.id, port = 5432, src = aws_security_group.bastion.id }
    mq_node      = { sg = aws_security_group.mq.id, port = 5671, src = module.eks.node_security_group_id }
    mq_node_ui   = { sg = aws_security_group.mq.id, port = 443, src = module.eks.node_security_group_id }
    mq_bastion   = { sg = aws_security_group.mq.id, port = 5671, src = aws_security_group.bastion.id }
    mq_bastionui = { sg = aws_security_group.mq.id, port = 443, src = aws_security_group.bastion.id }
    redis_node   = { sg = aws_security_group.redis.id, port = 6379, src = module.eks.node_security_group_id }
    redis_bast   = { sg = aws_security_group.redis.id, port = 6379, src = aws_security_group.bastion.id }
  }
}

resource "aws_vpc_security_group_ingress_rule" "data" {
  for_each                     = local.data_ingress
  security_group_id            = each.value.sg
  referenced_security_group_id = each.value.src
  ip_protocol                  = "tcp"
  from_port                    = each.value.port
  to_port                      = each.value.port
  description                  = each.key
}
