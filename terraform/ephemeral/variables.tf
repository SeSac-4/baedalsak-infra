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
  description = "환경 이름 (ENV_NAME). 앱 K8s namespace 로도 사용"
  type        = string
}

variable "azs" {
  description = "사용할 AZ 2개 (AZS), 예: [\"<region>a\", \"<region>c\"]"
  type        = list(string)

  validation {
    condition     = length(var.azs) == 2
    error_message = "azs 는 2개여야 합니다 (서브넷 CIDR 이 2개씩)."
  }
}

variable "cluster_name" {
  description = "EKS 클러스터 이름 (CLUSTER_NAME). 비우면 <project>-<env>"
  type        = string
  default     = ""
}

variable "secret_prefix" {
  description = "Secrets Manager 접두사 (SECRET_PREFIX). 비우면 <project>/<env>"
  type        = string
  default     = ""
}

variable "ssm_prefix" {
  description = "SSM 파라미터 경로 (SSM_PREFIX). 비우면 /<project>/<env>"
  type        = string
  default     = ""
}

variable "state_bucket" {
  description = "persistent state 를 읽을 S3 버킷 (bootstrap output state_bucket)"
  type        = string
}

variable "kubernetes_version" {
  description = "EKS 버전 (KUBERNETES_VERSION)"
  type        = string
}

# 매일 apply 시 직전 최종 스냅샷에서 복원 (워크플로가 최신 스냅샷을 찾아 넘김). 첫 apply 는 null
variable "db_snapshot_identifier" {
  type    = string
  default = null
}

# EKS 개발팀 접근 (IAM 사용자 ARN) — 권한은 eks.tf access_entries
variable "team_member_arns" {
  description = "EKS 접근 개발팀 ARN JSON 배열 (TEAM_MEMBER_ARNS Secret)"
  type        = list(string)
  default     = []
}

variable "infra_admin_users" {
  description = "EKS 클러스터 관리자 IAM 사용자 이름 (인프라 담당) — 계정 번호는 실행 시 조회"
  type        = list(string)
  default     = ["sesac-d5"]
}

