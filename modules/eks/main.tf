module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.31"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  cluster_endpoint_public_access           = true
  cluster_endpoint_private_access          = true
  enable_irsa                              = true
  enable_cluster_creator_admin_permissions = true

  vpc_id     = var.vpc_id
  subnet_ids = var.private_subnet_ids

  cluster_addons = {
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent = true
    }
    coredns = {
      most_recent = true
    }
  }

  eks_managed_node_group_defaults = {
    ami_type       = "AL2023_x86_64_STANDARD"
    instance_types = ["t3.medium"]
  }

  eks_managed_node_groups = {
    general = {
      min_size     = 2
      max_size     = 9
      desired_size = 2
      subnet_ids   = var.private_subnet_ids
    }
  }

  access_entries = {
    for role in var.aws_auth_roles : role.username => {
      kubernetes_groups   = role.groups
      kubernetes_username = role.username
      principal_arn       = role.rolearn
    }
  }

  tags = var.tags
}
