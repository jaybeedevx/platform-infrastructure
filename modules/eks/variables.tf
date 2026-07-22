variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "cluster_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.35"
}

variable "vpc_id" {
  description = "VPC ID where the cluster will be created"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for the EKS control plane and nodes"
  type        = list(string)
}

variable "aws_auth_roles" {
  description = "Additional AWS auth roles to map into the cluster"
  type        = list(any)
  default     = []
}

variable "tags" {
  description = "Tags applied to the cluster resources"
  type        = map(string)
  default     = {}
}
