# Pod Identity — 애드온과 서비스 파드의 AWS 권한 (액세스 키 없음)

module "lbc_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.0"

  name                            = "${local.name}-lbc"
  attach_aws_lb_controller_policy = true

  associations = {
    this = {
      cluster_name    = module.eks.cluster_name
      namespace       = "kube-system"
      service_account = "aws-load-balancer-controller"
    }
  }
}

module "ca_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.0"

  name                             = "${local.name}-cluster-autoscaler"
  attach_cluster_autoscaler_policy = true
  cluster_autoscaler_cluster_names = [module.eks.cluster_name]

  associations = {
    this = {
      cluster_name    = module.eks.cluster_name
      namespace       = "kube-system"
      service_account = "cluster-autoscaler"
    }
  }
}

module "eso_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.0"

  name                                  = "${local.name}-external-secrets"
  attach_external_secrets_policy        = true
  external_secrets_secrets_manager_arns = ["arn:aws:secretsmanager:${var.region}:${local.account}:secret:${local.secret_prefix}/*"]
  external_secrets_ssm_parameter_arns   = ["arn:aws:ssm:${var.region}:${local.account}:parameter${local.ssm_prefix}/*"]
  external_secrets_create_permission    = false

  associations = {
    this = {
      cluster_name    = module.eks.cluster_name
      namespace       = "external-secrets"
      service_account = "external-secrets"
    }
  }
}

# ---------- Pod Identity 공통 신뢰 정책 ----------
data "aws_iam_policy_document" "pod_trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

# ---------- Loki → S3 (앱 로그 저장소, 버킷은 persistent) — Fluent Bit 는 클러스터 안 Loki 로만 보내 AWS 권한 없음 ----------
resource "aws_iam_role" "loki" {
  name               = "${local.name}-loki"
  assume_role_policy = data.aws_iam_policy_document.pod_trust.json
}

resource "aws_iam_role_policy" "loki" {
  name = "s3-loki"
  role = aws_iam_role.loki.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["s3:ListBucket"], Resource = local.p.loki_bucket_arn },
      { Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"], Resource = "${local.p.loki_bucket_arn}/*" },
    ]
  })
}

resource "aws_eks_pod_identity_association" "loki" {
  cluster_name    = module.eks.cluster_name
  namespace       = "monitoring"
  service_account = "loki" # helm/addons/loki.yaml serviceAccount.name
  role_arn        = aws_iam_role.loki.arn
}

# ---------- Tempo → S3 (추적 저장소, 버킷은 persistent) — 앱은 클러스터 안 Tempo 로만 보내 AWS 권한 없음 ----------
resource "aws_iam_role" "tempo" {
  name               = "${local.name}-tempo"
  assume_role_policy = data.aws_iam_policy_document.pod_trust.json
}

resource "aws_iam_role_policy" "tempo" {
  name = "s3-tempo"
  role = aws_iam_role.tempo.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["s3:ListBucket"], Resource = local.p.tempo_bucket_arn },
      { Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"], Resource = "${local.p.tempo_bucket_arn}/*" },
    ]
  })
}

resource "aws_eks_pod_identity_association" "tempo" {
  cluster_name    = module.eks.cluster_name
  namespace       = "monitoring"
  service_account = "tempo" # helm/addons/tempo.yaml serviceAccount.name
  role_arn        = aws_iam_role.tempo.arn
}

# ---------- Grafana → CloudWatch 데이터소스 (로그 Insights · 지표 조회, 읽기 전용) ----------
resource "aws_iam_role" "grafana" {
  name               = "${local.name}-grafana"
  assume_role_policy = data.aws_iam_policy_document.pod_trust.json
}

resource "aws_iam_role_policy_attachment" "grafana" {
  role       = aws_iam_role.grafana.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchReadOnlyAccess"
}

# 비용 추정 알림 → SNS 알림 주제 (helm/addons/kube-prometheus-stack.yaml grafana.alerting)
resource "aws_iam_role_policy" "grafana_sns" {
  name = "sns-alerts"
  role = aws_iam_role.grafana.id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sns:Publish", Resource = local.p.alerts_topic_arn }]
  })
}

resource "aws_eks_pod_identity_association" "grafana" {
  cluster_name    = module.eks.cluster_name
  namespace       = "monitoring"
  service_account = "grafana" # helm/addons/kube-prometheus-stack.yaml grafana.serviceAccount.name
  role_arn        = aws_iam_role.grafana.arn
}

# ---------- store → S3 이미지 (presigned PUT URL 서명 · 업로드 확인 HeadObject) — 버킷은 persistent/images.tf ----------
#   presigned URL 은 서명한 주체(store 역할)의 권한으로 실행됨 → stores/ 아래 이미지 확장자 키에만 PutObject
#   (서버가 다른 형식을 서명해도 S3 가 AccessDenied — 확장자는 소문자 jpg·jpeg·png·webp)
resource "aws_iam_role" "store_images" {
  name               = "${local.name}-store-images"
  assume_role_policy = data.aws_iam_policy_document.pod_trust.json
}

resource "aws_iam_role_policy" "store_images" {
  name = "s3-images"
  role = aws_iam_role.store_images.id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = ["s3:PutObject", "s3:GetObject"], Resource = [for e in ["jpg", "jpeg", "png", "webp"] : "${local.p.image_bucket_arn}/stores/*.${e}"] }]
  })
}

resource "aws_eks_pod_identity_association" "store_images" {
  cluster_name    = module.eks.cluster_name
  namespace       = local.namespace
  service_account = "store"
  role_arn        = aws_iam_role.store_images.arn
}

# ---------- 메일 발송 서비스 → SES (payment · order · delivery) ----------
resource "aws_iam_role" "ses" {
  name               = "${local.name}-ses-sender"
  assume_role_policy = data.aws_iam_policy_document.pod_trust.json
}

resource "aws_iam_role_policy" "ses" {
  name = "ses-send"
  role = aws_iam_role.ses.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ses:SendEmail", "ses:SendRawEmail", "ses:SendTemplatedEmail"]
      Resource = "*"
    }]
  })
}

resource "aws_eks_pod_identity_association" "ses" {
  for_each        = toset(["payment", "order", "delivery"])
  cluster_name    = module.eks.cluster_name
  namespace       = local.namespace
  service_account = each.key
  role_arn        = aws_iam_role.ses.arn
}

# ---------- member → Cognito Admin API (가입·로그인, prod 풀만) ----------
data "aws_ssm_parameter" "cognito_user_pool_id" {
  name = "${local.ssm_prefix}/cognito_user_pool_id" # persistent/cognito.tf 가 씀
}

resource "aws_iam_role" "member" {
  name               = "${local.name}-member-cognito"
  assume_role_policy = data.aws_iam_policy_document.pod_trust.json
}

resource "aws_iam_role_policy" "member" {
  name = "cognito-admin"
  role = aws_iam_role.member.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "cognito-idp:AdminCreateUser",
        "cognito-idp:AdminSetUserPassword",
        "cognito-idp:AdminDeleteUser",
        "cognito-idp:AdminInitiateAuth",
        "cognito-idp:AdminAddUserToGroup",
      ]
      Resource = "arn:aws:cognito-idp:${var.region}:${local.account}:userpool/${nonsensitive(data.aws_ssm_parameter.cognito_user_pool_id.value)}"
    }]
  })
}

resource "aws_eks_pod_identity_association" "member" {
  cluster_name    = module.eks.cluster_name
  namespace       = local.namespace
  service_account = "member"
  role_arn        = aws_iam_role.member.arn
}

# ---------- Bastion (SSM) ----------
resource "aws_iam_role" "bastion" {
  name = "${local.name}-bastion"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "bastion_ssm" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "bastion" {
  name = "${local.name}-bastion"
  role = aws_iam_role.bastion.name
}

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_instance" "bastion" {
  ami                         = data.aws_ssm_parameter.al2023.value
  instance_type               = "t3.nano" # 개발 기간 최소 사양 (SSM 포트포워딩만) · 이전 값 t3.micro
  subnet_id                   = module.vpc.public_subnets[0]
  vpc_security_group_ids      = [aws_security_group.bastion.id]
  iam_instance_profile        = aws_iam_instance_profile.bastion.name
  associate_public_ip_address = true

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_size = 8
    volume_type = "gp3"
  }

  tags = { Name = "${local.name}-bastion" }
}
