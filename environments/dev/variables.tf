variable "aws_region" {
  description = "AWS region for the platform foundation"
  type        = string
  default     = "us-east-1"
}

variable "terraform_role_arn" {
  description = "Optional IAM role ARN used by CI/CD to assume access"
  type        = string
  default     = ""
}

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
  default     = "dev-platform"
}

variable "cluster_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.31"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.1.0.0/16"
}

variable "azs" {
  description = "Availability zones for the platform foundation"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b", "us-east-1c"]
}

variable "private_subnets" {
  description = "Private subnet CIDR blocks"
  type        = list(string)
  default     = ["10.1.1.0/24", "10.1.2.0/24", "10.1.3.0/24"]
}

variable "public_subnets" {
  description = "Public subnet CIDR blocks"
  type        = list(string)
  default     = ["10.1.101.0/24", "10.1.102.0/24", "10.1.103.0/24"]
}

variable "single_nat_gateway" {
  description = "Whether to create a single NAT gateway"
  type        = bool
  default     = true
}

variable "enable_flow_logs" {
  description = "Enable VPC flow logs"
  type        = bool
  default     = false
}

variable "admin_role_arn" {
  description = "Optional admin role ARN to map into the aws-auth configmap"
  type        = string
  default     = ""
}

variable "terraform_state_bucket_name" {
  description = "Name of the S3 bucket used for Terraform state"
  type        = string
  default     = "my-platform-terraform-state-use1"
}
