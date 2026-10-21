# =============================================================================
# bootstrap — 처음 한 번만, 관리자 자격 증명으로 로컬(WSL2)에서 apply
#   만드는 것: Terraform state 버킷, GitHub OIDC provider, GitHub Actions 역할
#   이후 모든 apply 는 GitHub Actions 가 이 역할로 실행
#   이 스택의 state 는 로컬 파일(terraform.tfstate)로 둠 — .gitignore 대상, 잃어버리면 import 로 복구
# =============================================================================
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}

# 값은 모두 환경변수 TF_VAR_* 로 받음 (.env.example 참고)
variable "region" {
  description = "AWS 리전 (AWS_REGION)"
  type        = string
}

variable "project" {
  description = "프로젝트 이름 (PROJECT)"
  type        = string
}

variable "env" {
  description = "환경 이름 (ENV_NAME)"
  type        = string
}

variable "state_bucket" {
  description = "만들 Terraform state 버킷 이름 (TF_STATE_BUCKET)"
  type        = string
}

# OIDC 토큰을 받을 수 있는 GitHub 레포 (owner/repo) — 워크플로가 있는 이 레포
variable "github_repo" {
  description = "GitHub 레포 owner/repo (GITHUB_REPO)"
  type        = string
}

provider "aws" {
  region = var.region
  default_tags {
    tags = { Project = var.project, Env = var.env, Stack = "bootstrap", ManagedBy = "terraform" }
  }
}

# ---------- Terraform state (S3 네이티브 잠금 use_lockfile) ----------
resource "aws_s3_bucket" "state" {
  bucket = var.state_bucket
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------- GitHub Actions OIDC ----------
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_policy_document" "gha_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      # 기존 형식 + immutable subject 형식(repo:<owner>@<id>/<repo>@<id>:...) — 새 레포는 후자가 기본
      values = [
        "repo:${var.github_repo}:*",
        "repo:${split("/", var.github_repo)[0]}@*/${split("/", var.github_repo)[1]}@*:*",
      ]
    }
  }
}

resource "aws_iam_role" "gha" {
  name                 = "${var.project}-${var.env}-github-actions"
  assume_role_policy   = data.aws_iam_policy_document.gha_trust.json
  max_session_duration = 7200 # apply·destroy 가 1시간을 넘을 수 있음
}

# terraform 이 VPC·EKS·IAM 까지 만들므로 관리자 수준
resource "aws_iam_role_policy_attachment" "gha_admin" {
  role       = aws_iam_role.gha.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

output "state_bucket" {
  value = aws_s3_bucket.state.bucket
}

output "github_actions_role_arn" {
  value = aws_iam_role.gha.arn
}
