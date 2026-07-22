# environments/dev/backend.tf
terraform {
  backend "s3" {
    bucket       = "my-platform-terraform-state-use1"
    key          = "dev/eks-foundation.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}