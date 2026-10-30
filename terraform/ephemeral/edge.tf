# =============================================================================
# 진입 (CloudFront · VPC origin · Route 53 alias) — ALB 와 함께 매일 만들고 지움
#   VPC origin 은 ALB ARN 에 묶이고, 배포가 VPC origin 을 쓰는 동안 둘 다 지울 수 없어서 배포까지 ephemeral 에 둠
#   (S3 프론트 · OAC · CF Function · 인증서는 persistent)
#   behavior ① /api/*  → VPC origin(internal ALB 443) · CachingDisabled · AllViewer
#   behavior ② /images/* → S3 이미지(OAC) · CachingOptimized · CF Function(/images 떼기) — persistent/images.tf
#   behavior ③ 기본 *  → S3(OAC) · CachingOptimized · CF Function(SPA 경로) · SecurityHeadersPolicy
# =============================================================================

resource "aws_cloudfront_vpc_origin" "alb" {
  vpc_origin_endpoint_config {
    name                   = local.name
    arn                    = aws_lb.internal.arn
    http_port              = 80
    https_port             = 443
    origin_protocol_policy = "https-only"
    origin_ssl_protocols {
      items    = ["TLSv1.2"]
      quantity = 1
    }
  }
}

# VPC origin 을 만들면 AWS 가 VPC 에 만드는 SG — ALB 443 은 여기서 오는 것만 허용
data "aws_security_group" "cloudfront_vpc_origin" {
  vpc_id     = module.vpc.vpc_id
  name       = "CloudFront-VPCOrigins-Service-SG"
  depends_on = [aws_cloudfront_vpc_origin.alb]
}

resource "aws_vpc_security_group_ingress_rule" "alb_https_cloudfront" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = data.aws_security_group.cloudfront_vpc_origin.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  description                  = "CloudFront VPC origin"
}

data "aws_cloudfront_cache_policy" "disabled" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_cache_policy" "optimized" {
  name = "Managed-CachingOptimized"
}

data "aws_cloudfront_origin_request_policy" "all_viewer" {
  name = "Managed-AllViewer"
}

data "aws_cloudfront_response_headers_policy" "security" {
  name = "Managed-SecurityHeadersPolicy"
}

resource "aws_cloudfront_distribution" "main" {
  enabled             = true
  comment             = local.name
  aliases             = [local.p.domain_name]
  default_root_object = "index.html"
  price_class         = "PriceClass_200"
  http_version        = "http2and3"

  origin {
    origin_id                = "s3-front"
    domain_name              = local.p.front_bucket_domain
    origin_access_control_id = local.p.front_oac_id
  }

  origin {
    origin_id                = "s3-images"
    domain_name              = local.p.image_bucket_domain
    origin_access_control_id = local.p.front_oac_id # OAC 는 버킷에 묶이지 않아 프론트와 같이 씀
  }

  origin {
    origin_id   = "alb"
    domain_name = aws_lb.internal.dns_name
    vpc_origin_config {
      vpc_origin_id       = aws_cloudfront_vpc_origin.alb.id
      origin_read_timeout = 30
    }
  }

  ordered_cache_behavior {
    path_pattern             = "/api/*"
    target_origin_id         = "alb"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = data.aws_cloudfront_cache_policy.disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer.id
    compress                 = true
  }

  # 키가 uuid 라 같은 주소의 내용이 바뀌지 않음 → 캐시 길게 (CachingOptimized 기본 1일 · 최대 1년)
  ordered_cache_behavior {
    path_pattern               = "/images/*"
    target_origin_id           = "s3-images"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD"]
    cached_methods             = ["GET", "HEAD"]
    cache_policy_id            = data.aws_cloudfront_cache_policy.optimized.id
    response_headers_policy_id = local.p.images_headers_policy_id # nosniff · CSP sandbox (persistent/images.tf)
    compress                   = true

    function_association {
      event_type   = "viewer-request"
      function_arn = local.p.images_function_arn
    }
    function_association {
      event_type   = "viewer-response"
      function_arn = local.p.images_type_function_arn
    }
  }

  default_cache_behavior {
    target_origin_id           = "s3-front"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD"]
    cached_methods             = ["GET", "HEAD"]
    cache_policy_id            = data.aws_cloudfront_cache_policy.optimized.id
    response_headers_policy_id = data.aws_cloudfront_response_headers_policy.security.id
    compress                   = true

    function_association {
      event_type   = "viewer-request"
      function_arn = local.p.spa_function_arn
    }
  }

  viewer_certificate {
    acm_certificate_arn      = local.p.cloudfront_certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  depends_on = [aws_vpc_security_group_ingress_rule.alb_https_cloudfront]
}

# S3 프론트는 이 배포만 읽을 수 있음 (OAC)
data "aws_iam_policy_document" "front" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${local.p.front_bucket_arn}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.main.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "front" {
  bucket = local.p.front_bucket
  policy = data.aws_iam_policy_document.front.json
}

# S3 이미지도 이 배포만 읽을 수 있음 (OAC) — 업로드는 store 의 presigned URL 로만
data "aws_iam_policy_document" "images" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${local.p.image_bucket_arn}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.main.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "images" {
  bucket = local.p.image_bucket
  policy = data.aws_iam_policy_document.images.json
}

resource "aws_route53_record" "main" {
  for_each = toset(["A", "AAAA"])
  zone_id  = local.p.zone_id
  name     = local.p.domain_name
  type     = each.key
  alias {
    name                   = aws_cloudfront_distribution.main.domain_name
    zone_id                = aws_cloudfront_distribution.main.hosted_zone_id
    evaluate_target_health = false
  }
}
