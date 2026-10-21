# EKS (var.kubernetes_version) · 관리형 노드그룹 1개(t3.large, 2/2/4, AL2023) · access entry(API 모드)
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = local.cluster_name
  kubernetes_version = var.kubernetes_version

  endpoint_public_access  = true
  endpoint_private_access = true
  authentication_mode     = "API"

  # apply 하는 주체(GitHub Actions 역할)가 클러스터 관리자
  enable_cluster_creator_admin_permissions = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  addons = {
    vpc-cni                = { before_compute = true }
    eks-pod-identity-agent = { before_compute = true }
    kube-proxy             = {}
    coredns                = {}
  }

  eks_managed_node_groups = {
    default = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = ["t3.large"]
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

  access_entries = {
    for i, arn in var.team_member_arns : "team-${i}" => {
      principal_arn = arn
      policy_associations = {
        main = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/${var.team_member_policy}"
          access_scope = { type = "cluster" }
        }
      }
    }
  }
}
