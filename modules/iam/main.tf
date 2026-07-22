module "ebs_csi_irsa" {
  source = "./irsa-role"

  name                 = "ebs-csi"
  namespace            = "kube-system"
  service_account_name = "ebs-csi-controller-sa"
  oidc_provider_arn    = var.oidc_provider_arn
  issuer_url           = var.oidc_provider_url
  policy_arns          = ["arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"]
}

module "efs_csi_irsa" {
  source = "./irsa-role"

  name                 = "efs-csi"
  namespace            = "kube-system"
  service_account_name = "efs-csi-controller-sa"
  oidc_provider_arn    = var.oidc_provider_arn
  issuer_url           = var.oidc_provider_url
  policy_arns          = ["arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy"]
}

module "lb_controller_irsa" {
  source = "./irsa-role"

  name                 = "aws-lb-controller"
  namespace            = "kube-system"
  service_account_name = "aws-load-balancer-controller"
  oidc_provider_arn    = var.oidc_provider_arn
  issuer_url           = var.oidc_provider_url
  policy_arns = [
    "arn:aws:iam::aws:policy/ElasticLoadBalancingFullAccess",
    "arn:aws:iam::aws:policy/AmazonEC2FullAccess"
  ]
}
