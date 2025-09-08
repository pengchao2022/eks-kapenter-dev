# 创建 EKS 集群
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 19.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  vpc_id                   = var.vpc_id
  subnet_ids               = var.private_subnet_ids
  control_plane_subnet_ids = var.private_subnet_ids

  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = false

  # 禁用自动创建 aws-auth configmap
  create_aws_auth_configmap = false
  manage_aws_auth_configmap = false

  eks_managed_node_groups = {}
  self_managed_node_groups = {}
  fargate_profiles = {}

  # 禁用 IRSA（我们手动创建）
  enable_irsa = false

  tags = {
    Environment = var.environment
    Terraform   = "true"
    Project     = "eks-karpenter"
  }
}

# 等待集群就绪
resource "time_sleep" "wait_for_cluster" {
  depends_on = [module.eks]

  create_duration = "2m"
}

# Karpenter需要的基础设施标签
resource "aws_ec2_tag" "private_subnet_tags" {
  for_each    = toset(var.private_subnet_ids)
  resource_id = each.key
  key         = "karpenter.sh/discovery"
  value       = var.cluster_name

  depends_on = [time_sleep.wait_for_cluster]
}

resource "aws_ec2_tag" "vpc_tag" {
  resource_id = var.vpc_id
  key         = "karpenter.sh/discovery"
  value       = var.cluster_name

  depends_on = [time_sleep.wait_for_cluster]
}

resource "aws_ec2_tag" "cluster_security_group_tag" {
  resource_id = module.eks.cluster_security_group_id
  key         = "karpenter.sh/discovery"
  value       = var.cluster_name

  depends_on = [time_sleep.wait_for_cluster]
}

resource "aws_ec2_tag" "node_security_group_tag" {
  resource_id = module.eks.node_security_group_id
  key         = "karpenter.sh/discovery"
  value       = var.cluster_name

  depends_on = [time_sleep.wait_for_cluster]
}