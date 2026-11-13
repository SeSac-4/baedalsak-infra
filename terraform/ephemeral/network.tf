# VPC 10.0.0.0/16 — public /24 ×2 · EKS private /20 ×2 · ALB private /27 ×2 · data /24 ×2 (서브넷 8개), NAT 1개(azs[0])
#   ALB 전용 서브넷: NetworkPolicy 의 ALB 허용 대역(alb_subnet_cidrs)에 파드 IP 가 섞이지 않게 분리
#   private 라우트 테이블(NAT)을 같이 씀 — ALB 의 Cognito 로그인(authenticate-cognito)이 Cognito 엔드포인트로 나가야 함
locals {
  eks_subnet_cidrs = ["10.0.32.0/20", "10.0.48.0/20"]
  alb_subnet_cidrs = ["10.0.66.0/27", "10.0.66.32/27"]
  eks_subnets      = slice(module.vpc.private_subnets, 0, 2)
  alb_subnets      = slice(module.vpc.private_subnets, 2, 4)
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = local.name
  cidr = "10.0.0.0/16"
  azs  = local.azs

  public_subnets   = ["10.0.0.0/24", "10.0.1.0/24"]
  private_subnets  = concat(local.eks_subnet_cidrs, local.alb_subnet_cidrs) # 앞 2개 EKS · 뒤 2개 ALB (azs 순서)
  database_subnets = ["10.0.64.0/24", "10.0.65.0/24"]

  create_database_subnet_group       = false
  create_database_subnet_route_table = true # data 서브넷은 인터넷 경로 없음

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true
  enable_dns_support   = true

  public_subnet_suffix   = "public"
  private_subnet_names   = [for i, az in concat(local.azs, local.azs) : "${local.name}-${i < 2 ? "eks" : "alb"}-${az}"]
  database_subnet_suffix = "data"
}

# ---------- 보안그룹 ----------
# internal ALB: 443 은 CloudFront VPC origin SG 에서만 (edge.tf), 80 은 클러스터 안(smoke test)·Bastion 터널만
resource "aws_security_group" "alb" {
  name        = "${local.name}-alb"
  description = "internal ALB"
  vpc_id      = module.vpc.vpc_id

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
    alb_node     = { sg = aws_security_group.alb.id, port = 80, src = module.eks.node_security_group_id }
    alb_bastion  = { sg = aws_security_group.alb.id, port = 80, src = aws_security_group.bastion.id }
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
