# ---------- SMS (SNS 문자) 계정 설정 — member 휴대폰 인증 (#39) ----------
#   샌드박스: 콘솔에서 등록한 팀원 번호로만 발송 (해제는 AWS 지원 요청 — MVP 이후)
#   월 한도 1달러 = 계정 기본 한도. 더 올리려면 AWS 지원 요청 먼저 (그 전에 올리면 apply 실패)
resource "aws_sns_sms_preferences" "this" {
  default_sms_type    = "Transactional" # 인증 코드용: 가격보다 전달 우선
  monthly_spend_limit = 1
}
