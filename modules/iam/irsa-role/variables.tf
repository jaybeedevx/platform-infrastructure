variable "name" {
  description = "Base name for the IRSA role"
  type        = string
}

variable "namespace" {
  description = "Kubernetes namespace for the service account"
  type        = string
}

variable "service_account_name" {
  description = "Name of the Kubernetes service account"
  type        = string
}

variable "oidc_provider_arn" {
  description = "ARN of the EKS OIDC provider"
  type        = string
}

variable "issuer_url" {
  description = "Issuer URL of the EKS OIDC provider"
  type        = string
}

variable "policy_arns" {
  description = "IAM policy ARNs to attach to the role"
  type        = list(string)
  default     = []
}
