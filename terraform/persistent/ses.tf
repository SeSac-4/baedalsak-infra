# ---------- SES 도메인 자격 + DKIM (Route 53) ----------
#   샌드박스 해제(프로덕션 액세스)는 콘솔에서 수동 요청 — 그 전에는 검증된 주소로만 발송
resource "aws_sesv2_email_identity" "domain" {
  email_identity = var.domain_name
}

resource "aws_route53_record" "ses_dkim" {
  count   = 3 # Easy DKIM 토큰은 항상 3개
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "${aws_sesv2_email_identity.domain.dkim_signing_attributes[0].tokens[count.index]}._domainkey.${var.domain_name}"
  type    = "CNAME"
  ttl     = 600
  records = ["${aws_sesv2_email_identity.domain.dkim_signing_attributes[0].tokens[count.index]}.dkim.amazonses.com"]
}

# SES 샌드박스 동안 수신자도 인증 필요 — 일일 비용 메일 수신자(ALERT_EMAILS)에게 인증 메일 발송, 링크 1회 클릭
resource "aws_sesv2_email_identity" "recipient" {
  for_each       = toset(var.alert_emails)
  email_identity = each.value
}
