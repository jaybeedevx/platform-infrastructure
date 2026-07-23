locals {
  common_tags = {
    Environment = "dev"
    ManagedBy   = "Terraform"
    Project     = "platform-foundation"
  }

  aws_auth_roles = var.admin_role_arn != "" ? [
    {
      rolearn  = var.admin_role_arn
      username = "admin-role"
      groups   = ["system:masters"]
    }
  ] : []
}

module "vpc" {
  source = "../../modules/vpc"

  name               = var.cluster_name
  cidr               = var.vpc_cidr
  azs                = var.azs
  private_subnets    = var.private_subnets
  public_subnets     = var.public_subnets
  cluster_name       = var.cluster_name
  enable_flow_logs   = var.enable_flow_logs
  single_nat_gateway = var.single_nat_gateway
  tags               = local.common_tags
}

module "eks" {
  source = "../../modules/eks"

  cluster_name       = var.cluster_name
  cluster_version    = var.cluster_version
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  aws_auth_roles     = local.aws_auth_roles
  tags               = local.common_tags
}

module "iam" {
  source = "../../modules/iam"

  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url
}

module "addons" {
  source = "../../modules/addons"

  cluster_name                = module.eks.cluster_name
  ebs_csi_irsa_role_arn       = module.iam.ebs_csi_irsa_role_arn
  efs_csi_irsa_role_arn       = module.iam.efs_csi_irsa_role_arn
  lb_controller_irsa_role_arn = module.iam.lb_controller_irsa_role_arn
  oidc_provider_arn           = module.eks.oidc_provider_arn
  oidc_provider_url           = module.eks.oidc_provider_url

  depends_on = [module.eks, module.iam]
}