# ---------- 가게·메뉴 이미지 (store 가 presigned PUT URL 발급 → 프론트가 S3 에 직접 업로드) ----------
#   키   : stores/{storeId}/{uuid}.{ext} (store 가 만듦)
#   조회 : https://<DOMAIN_NAME>/images/<키> → CloudFront /images/* (ephemeral/edge.tf) → 아래 함수가 /images 를 떼고 → 이 버킷(OAC)
#   프론트 버킷과 분리 — frontend.yml 의 s3 sync 가 이미지를 지우지 않게. 매일 지우지 않음(persistent)
resource "aws_s3_bucket" "images" {
  bucket = "${local.name}-images-${local.account}"
}

resource "aws_s3_bucket_public_access_block" "images" {
  bucket                  = aws_s3_bucket.images.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "images" {
  bucket = aws_s3_bucket.images.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_ownership_controls" "images" {
  bucket = aws_s3_bucket.images.id
  rule { object_ownership = "BucketOwnerEnforced" }
}

# 브라우저가 presigned URL 로 직접 PUT (배포 도메인 · 로컬 vite)
resource "aws_s3_bucket_cors_configuration" "images" {
  bucket = aws_s3_bucket.images.id
  cors_rule {
    allowed_methods = ["PUT"]
    allowed_origins = ["https://${var.domain_name}", "http://localhost:5173"]
    allowed_headers = ["Content-Type"]
    expose_headers  = ["ETag"]
    max_age_seconds = 3000
  }
}

# 중간에 끊긴 업로드 조각 정리. 저장 안 된 · 교체 전 이미지는 MVP 에선 그대로 둠
resource "aws_s3_bucket_lifecycle_configuration" "images" {
  bucket = aws_s3_bucket.images.id
  rule {
    id     = "abort-incomplete-upload"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload { days_after_initiation = 1 }
  }
}

# /images/stores/1/a.jpg → /stores/1/a.jpg (버킷 키에는 /images 가 없음). /images/* behavior 에만 붙임
resource "aws_cloudfront_function" "images" {
  name    = "${local.name}-images-path"
  runtime = "cloudfront-js-2.0"
  publish = true
  code    = <<-EOT
    function handler(event) {
      var req = event.request;
      req.uri = req.uri.replace(/^\/images\//, '/');
      return req;
    }
  EOT
}

# deploy.sh 가 store 에 env 로 넣음 (IMAGE_BUCKET · IMAGE_BASE_URL)
resource "aws_ssm_parameter" "image_bucket" {
  name  = "${local.ssm_prefix}/image_bucket"
  type  = "String"
  value = aws_s3_bucket.images.bucket
}

resource "aws_ssm_parameter" "image_base_url" {
  name  = "${local.ssm_prefix}/image_base_url"
  type  = "String"
  value = "https://${var.domain_name}/images"
}

output "image_bucket" {
  value = aws_s3_bucket.images.bucket
}

output "image_bucket_arn" {
  value = aws_s3_bucket.images.arn
}

output "image_bucket_domain" {
  value = aws_s3_bucket.images.bucket_regional_domain_name
}

output "images_function_arn" {
  value = aws_cloudfront_function.images.arn
}
