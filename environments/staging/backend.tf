# environments/staging/backend.tf
terraform {
  backend "s3" {
    bucket       = "my-platform-terraform-state-use1"
    key          = "staging/eks-foundation.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}