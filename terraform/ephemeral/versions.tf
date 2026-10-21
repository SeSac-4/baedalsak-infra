# =============================================================================
# ephemeral — 매일 apply · destroy 하는 스택
#   VPC · NAT · EKS(관리형 노드그룹) · internal ALB · 대상 그룹 · RDS · Amazon MQ · ElastiCache · Bastion
#   Pod Identity 역할 · Parameter Store 값
# =============================================================================
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
  # backend 블록은 변수를 못 씀 → bucket·region 은 init 때 -backend-config 로 넘김
  #   terraform init -backend-config="bucket=$TF_STATE_BUCKET" -backend-config="region=$AWS_REGION"
  backend "s3" {
    key          = "ephemeral/terraform.tfstate"
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = { Project = var.project, Env = var.env, Stack = "ephemeral", ManagedBy = "terraform" }
  }
}

data "terraform_remote_state" "persistent" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "persistent/terraform.tfstate"
    region = var.region
  }
}

data "aws_caller_identity" "this" {}

locals {
  name          = "${var.project}-${var.env}" # 리소스 이름 규칙 (persistent·스크립트·워크플로 동일)
  cluster_name  = coalesce(var.cluster_name, local.name)
  namespace     = var.env # 앱 K8s namespace = 환경 이름 (scripts/aws/env.sh 의 NS)
  secret_prefix = coalesce(var.secret_prefix, "${var.project}/${var.env}")
  ssm_prefix    = coalesce(var.ssm_prefix, "/${var.project}/${var.env}")
  azs           = var.azs
  p             = data.terraform_remote_state.persistent.outputs
  account       = data.aws_caller_identity.this.account_id
}
