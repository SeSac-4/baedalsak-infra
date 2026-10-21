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

variable "secret_prefix" {
  description = "Secrets Manager 접두사 (SECRET_PREFIX). 비우면 <project>/<env>"
  type        = string
  default     = ""
}

variable "log_group_name" {
  description = "컨테이너 로그 그룹 (LOG_GROUP). 비우면 /<project>/<env>/containers"
  type        = string
  default     = ""
}
