# ---------- 프론트 (S3 · OAC · CF Function) ----------
# CloudFront 배포는 VPC origin(= 매일 새로 만드는 ALB)에 묶여 있어 ephemeral/edge.tf 에서 함께 만들고 지움
# 버킷 정책(이 배포만 읽기)도 배포 ARN 이 매일 바뀌므로 ephemeral 에서 붙임
resource "aws_s3_bucket" "front" {
  bucket = "${local.name}-front-${local.account}"
}

resource "aws_s3_bucket_public_access_block" "front" {
  bucket                  = aws_s3_bucket.front.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "front" {
  bucket = aws_s3_bucket.front.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_ownership_controls" "front" {
  bucket = aws_s3_bucket.front.id
  rule { object_ownership = "BucketOwnerEnforced" }
}

resource "aws_cloudfront_origin_access_control" "front" {
  name                              = "${local.name}-front"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# SPA 새로고침 404 방지: 마지막 경로 조각에 확장자가 없으면 /index.html (기본 behavior 에만 붙임 → API 응답은 그대로)
resource "aws_cloudfront_function" "spa" {
  name    = "${local.name}-spa-route"
  runtime = "cloudfront-js-2.0"
  publish = true
  code    = <<-EOT
    function handler(event) {
      var req = event.request;
      var last = req.uri.substring(req.uri.lastIndexOf('/') + 1);
      if (last.indexOf('.') === -1) { req.uri = '/index.html'; }
      return req;
    }
  EOT
}

resource "aws_ssm_parameter" "front_bucket" {
  name  = "${local.ssm_prefix}/front_bucket"
  type  = "String"
  value = aws_s3_bucket.front.bucket
}
