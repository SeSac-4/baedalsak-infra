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

# EKS 팀원 접근 (IAM 사용자/역할 ARN). 권한 범위는 결정 전이라 기본은 조회 전용
variable "team_member_arns" {
  description = "EKS 접근 팀원 ARN JSON 배열 (TEAM_MEMBER_ARNS)"
  type        = list(string)
  default     = []
}

variable "team_member_policy" {
  description = "TEAM_MEMBER_POLICY: AmazonEKSAdminViewPolicy(조회) / AmazonEKSClusterAdminPolicy(관리자)"
  type        = string
  default     = "AmazonEKSAdminViewPolicy"
}

# ACM ②(서울) 인증서 ARN. 도메인 구매·검증 전에는 비워 두고 HTTP 80 리스너만 사용
variable "alb_certificate_arn" {
  description = "ALB 인증서 ARN (ALB_CERTIFICATE_ARN). 비우면 HTTP 80 만"
  type        = string
  default     = ""
}
