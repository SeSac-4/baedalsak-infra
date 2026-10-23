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

variable "ssm_prefix" {
  description = "SSM 파라미터 경로 (SSM_PREFIX). 비우면 /<project>/<env>"
  type        = string
  default     = ""
}

variable "domain_name" {
  description = "서비스 도메인 (DOMAIN_NAME), Route 53 에서 구매한 것 — 예: baedalsak.click"
  type        = string
}

variable "github_repo" {
  description = "켜기·끄기를 실행할 인프라 레포 owner/repo (워크플로가 github.repository 로 넘김)"
  type        = string
}

variable "github_ref" {
  description = "켜기·끄기 워크플로를 실행할 브랜치 (워크플로가 기본 브랜치로 넘김)"
  type        = string
}

variable "schedule_up" {
  description = "켜기 시각 (EventBridge Scheduler cron, Asia/Seoul)"
  type        = string
  default     = "cron(30 9 ? * MON-FRI *)" # 10:00 까지 사용 가능하도록 09:30 시작 (켜기 약 25분)
}

variable "schedule_down" {
  description = "끄기 시각 (EventBridge Scheduler cron, Asia/Seoul)"
  type        = string
  default     = "cron(0 19 ? * MON-FRI *)"
}

variable "budget_daily_usd" {
  description = "일일 예산 USD (BUDGET_DAILY_USD). 실제 비용이 넘으면 끄기 실행"
  type        = number
  default     = 10
}

variable "budget_warn_usd" {
  description = "일일 비용 경고 USD (BUDGET_WARN_USD). 넘으면 메일만"
  type        = number
  default     = 5
}

variable "alert_emails" {
  description = "알림 메일 수신자 JSON 배열 (ALERT_EMAILS) — 알람 · 켜기/끄기 결과 · 예산"
  type        = list(string)
  default     = []
}
