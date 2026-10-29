# EKS (var.kubernetes_version) · 관리형 노드그룹 1개(t3.large, 2/2/4, AL2023) · access entry(API 모드)
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = local.cluster_name
  kubernetes_version = var.kubernetes_version

  endpoint_public_access  = true
  endpoint_private_access = true
  authentication_mode     = "API"

  # Secret 암호화는 EKS 기본(AWS 관리 키) — 고객 관리 KMS 키를 매일 만들지 않음
  create_kms_key    = false
  encryption_config = null

  # apply 하는 주체(GitHub Actions 역할)가 클러스터 관리자
  enable_cluster_creator_admin_permissions = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  addons = {
    # NetworkPolicy 적용 (aws-node 안의 network policy agent) — monitoring 의 Grafana 를 앱 파드에서 못 들어오게
    vpc-cni                = { before_compute = true, configuration_values = jsonencode({ enableNetworkPolicy = "true" }) }
    eks-pod-identity-agent = { before_compute = true }
    kube-proxy             = {}
    coredns                = {}
  }

  eks_managed_node_groups = {
    default = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = ["t3.large"] # 2 vCPU · 8GiB · 파드 35개/노드 (앱 7개 × 768Mi 메모리 때문에 medium 대신 유지)
      capacity_type  = "ON_DEMAND"

      min_size     = 2
      max_size     = 4
      desired_size = 2

      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 30
            volume_type           = "gp3"
            delete_on_termination = true
          }
        }
      }
    }
  }

  # ALB → 파드(ip 타겟): 8080 트래픽, 8081 헬스체크
  node_security_group_additional_rules = {
    alb_to_pods = {
      description              = "internal ALB to pods 8080-8081"
      type                     = "ingress"
      protocol                 = "tcp"
      from_port                = 8080
      to_port                  = 8081
      source_security_group_id = aws_security_group.alb.id
    }
  }

  # 인프라(var.infra_admin_users) = 클러스터 관리자 · 개발팀(TEAM_MEMBER_ARNS) = 전체 조회 + prod·monitoring 수정(로그·재시작·port-forward)
  #   개발팀 IAM 이 AdministratorAccess 라 실수 방지용 구분 (보안 경계 아님)
  access_entries = merge(
    { for u in var.infra_admin_users : "admin-${u}" => {
      principal_arn       = "arn:aws:iam::${local.account}:user/${u}"
      policy_associations = { admin = { policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy", access_scope = { type = "cluster" } } }
    } },
    { for arn in local.team_arns : "team-${element(split("/", arn), 1)}" => {
      principal_arn = arn
      policy_associations = {
        view = { policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy", access_scope = { type = "cluster" } }
        edit = { policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy", access_scope = { type = "namespace", namespaces = [local.namespace, "monitoring"] } }
      }
    } },
  )
}

locals {
  # 관리자가 TEAM_MEMBER_ARNS 에도 있으면 같은 사용자 access entry 가 2개가 돼 apply 실패 → 개발팀 목록에서 뺌
  team_arns = [for a in var.team_member_arns : a if !contains(var.infra_admin_users, element(split("/", a), 1))]
}
