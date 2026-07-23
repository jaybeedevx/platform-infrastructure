# Platform Infrastructure

This repository provisions the base AWS EKS platform that the GitOps application layer will build on top of.

## What this platform includes

- VPC with public and private subnets across three availability zones
- NAT gateway for outbound access from private subnets
- EKS cluster with a managed node group
- OIDC provider and IRSA support for Kubernetes service accounts
- EBS CSI driver
- EFS CSI driver
- AWS Load Balancer Controller
- Terraform-ready structure for environment promotion and future automation

## Repository structure

- environments/dev: development environment entrypoint and provider configuration
- modules/vpc: VPC, subnets, NAT gateway, and routing
- modules/eks: EKS cluster and managed node groups
- modules/iam: IRSA role definitions for CSI drivers and the load balancer controller
- modules/addons: Helm-based add-ons for EBS CSI, EFS CSI, and AWS Load Balancer Controller

## Prerequisites

Install and configure the following on the machine that will run Terraform:

- Terraform
- AWS CLI
- kubectl
- Optional: Helm

Make sure your AWS credentials are available:

```bash
aws configure
```

## Quick start

### 1. Change to the environment directory

```bash
cd /path/to/platform-infrastructure/environments/dev
```

### 2. Review the environment values

Edit the values in [environments/dev/terraform.tfvars](environments/dev/terraform.tfvars) if you need to change the cluster name, region, or Kubernetes version.

### 3. Bootstrap the Terraform backend with Terraform (first run only)

The backend bucket must exist before the dev backend can initialize. Create it from the dedicated bootstrap configuration:

```bash
cd /path/to/platform-infrastructure/environments/bootstrap
terraform init
terraform apply
```

Then initialize the dev environment:

```bash
cd ../dev
terraform init -reconfigure
```

### 4. Create the platform

```bash
terraform apply
```

### 5. Connect to the cluster

After the apply finishes, configure kubectl:

```bash
aws eks update-kubeconfig --region us-east-1 --name dev-platform
```

Verify that the cluster and nodes are healthy:

```bash
kubectl get nodes
kubectl get pods -n kube-system
```

## Useful follow-up commands

- View the Terraform state:

```bash
terraform state list
```

- Destroy the platform when needed:

```bash
tterraform destroy
```

- Check the EBS CSI controller deployment:

```bash
kubectl get deployment ebs-csi-controller -n kube-system
```

## Validation for contributors

Before pushing Terraform changes, run the local validation checks:

```bash
pre-commit install
pre-commit run --all-files
```

Or run the helper script directly:

```bash
./scripts/validate.sh
```

These checks validate Terraform formatting and configuration syntax for the dev environment.

## Next steps

Once the platform is running, you can install Argo CD and connect the GitOps application repository to the cluster.
