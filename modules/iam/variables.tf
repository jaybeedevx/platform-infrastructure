variable "oidc_provider_arn" {
  description = "The ARN of the EKS OIDC provider"
  type        = string
}

variable "oidc_provider_url" {
  description = "The issuer URL of the EKS OIDC provider"
  type        = string
}

variable "cluster_oidc_issuer_url" {
  type = string
}