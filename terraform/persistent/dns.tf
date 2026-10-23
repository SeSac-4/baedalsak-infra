# ---------- Route 53 · ACM ①② ----------
# 존은 도메인 구매 시 Route 53 이 자동으로 만든 것을 참조만 함 (지우면 네임서버가 바뀌므로 Terraform 이 소유하지 않음)
data "aws_route53_zone" "main" {
  name         = var.domain_name
  private_zone = false
}

# ACM ① (us-east-1) — CloudFront 용, 도메인 + 와일드카드
resource "aws_acm_certificate" "cloudfront" {
  provider                  = aws.us_east_1
  domain_name               = var.domain_name
  subject_alternative_names = ["*.${var.domain_name}"]
  validation_method         = "DNS"
  lifecycle { create_before_destroy = true }
}

# ACM ② (서울) — internal ALB 용. CloudFront 가 Host(도메인)를 그대로 넘기므로 같은 이름
resource "aws_acm_certificate" "alb" {
  domain_name       = var.domain_name
  validation_method = "DNS"
  lifecycle { create_before_destroy = true }
}

# 검증 레코드는 도메인 이름으로 정해져서 ①·②·와일드카드(*.)가 모두 같은 레코드 1개
#   for_each 키는 plan 때 알 수 있는 domain_name 으로 (레코드 이름은 인증서 생성 후에야 알 수 있음)
locals {
  acm_validation = {
    for o in aws_acm_certificate.cloudfront.domain_validation_options :
    trimprefix(o.domain_name, "*.") => o...
  }
}

resource "aws_route53_record" "acm_validation" {
  for_each        = local.acm_validation
  zone_id         = data.aws_route53_zone.main.zone_id
  name            = each.value[0].resource_record_name
  type            = each.value[0].resource_record_type
  records         = [each.value[0].resource_record_value]
  ttl             = 300
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "cloudfront" {
  provider                = aws.us_east_1
  certificate_arn         = aws_acm_certificate.cloudfront.arn
  validation_record_fqdns = [for r in aws_route53_record.acm_validation : r.fqdn]
}

resource "aws_acm_certificate_validation" "alb" {
  certificate_arn         = aws_acm_certificate.alb.arn
  validation_record_fqdns = [for r in aws_route53_record.acm_validation : r.fqdn]
}
