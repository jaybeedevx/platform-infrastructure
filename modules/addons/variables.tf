variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "ebs_csi_irsa_role_arn" {
  description = "ARN of the EBS CSI driver IRSA role"
  type        = string
}

variable "efs_csi_irsa_role_arn" {
  description = "ARN of the EFS CSI driver IRSA role"
  type        = string
}

variable "lb_controller_irsa_role_arn" {
  description = "ARN of the AWS Load Balancer Controller IRSA role"
  type        = string
}

variable "oidc_provider_arn" {
  description = "The ARN of the EKS OIDC provider"
  type        = string
}

variable "oidc_provider_url" {
  description = "The issuer URL of the EKS OIDC provider"
  type        = string
}
