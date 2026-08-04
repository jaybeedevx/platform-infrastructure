# Platform Infrastructure

This repository provisions the AWS EKS platform and the GitOps tooling layer that applications build on top of, using Terraform. It uses a multi-environment layout (`dev`, `staging`, `production`) that shares a set of reusable modules, a dedicated `bootstrap` environment for the S3 state backend, and GitHub Actions CI/CD wired up through an OIDC role.

## What this platform includes

- **VPC** with public and private subnets across three availability zones, a NAT gateway for outbound access from private subnets, and optional VPC flow logs
- **EKS cluster** on `terraform-aws-modules/eks/aws` v20.x, Kubernetes 1.36, with an AL2023 managed node group (`t3.medium`, min 2 / max 9)
- **Cluster add-ons**: kube-proxy, VPC CNI, CoreDNS
- **OIDC provider + IRSA** for Kubernetes service accounts
- **IAM roles** (via the shared `irsa-role` module) for EBS CSI, EFS CSI, the AWS Load Balancer Controller, External Secrets, and the Argo CD application controller
- **Admin access** through EKS access entries via the `admin_role_arn` variable
- **Helm add-ons** installed into the cluster:

  | Add-on | Chart version | Namespace |
  |---|---|---|
  | AWS Load Balancer Controller | 1.7.1 | kube-system |
  | AWS EBS CSI driver | 2.62.0 | kube-system |
  | AWS EFS CSI driver | 2.5.0 | kube-system |
  | Metrics Server | 3.12.0 | kube-system |
  | cert-manager | 1.14.0 | cert-manager |
  | External Secrets Operator | 0.9.11 | external-secrets |
  | Argo CD | 10.2.1 (image v3.4.5) | argocd |

- **CI/CD**: GitHub Actions with OIDC role assumption — validate, lint, Trivy scan, plan-with-PR-comment, and apply on `main`

## Repository structure

```
.
├── environments/
│   ├── bootstrap/        # S3 bucket for the remote Terraform state backend
│   ├── dev/              # dev environment entrypoint (VPC + EKS + IAM + add-ons)
│   ├── staging/          # staging environment entrypoint (same modules)
│   └── production/       # production environment entrypoint (same modules)
├── modules/
│   ├── vpc/              # VPC, subnets, NAT gateway, routing, optional flow logs
│   ├── eks/              # EKS cluster and managed node group (wraps the community EKS module)
│   ├── iam/              # IRSA role definitions for CSI drivers, LB controller, Argo CD
│   │   └── irsa-role/    # reusable IRSA role module (OIDC trust + attached policies)
│   └── addons/           # Helm releases: LB controller, CSI drivers, Metrics Server, cert-manager,
│                         # External Secrets, Argo CD
├── docs/
│   ├── ci-cd.md              # pipeline runbook: PR evidence → controlled apply
│   └── production-setup.md   # production runbook: prereqs, approval gate, promotion
├── scripts/
│   ├── validate.sh              # local fmt + validate checks
│   └── bootstrap-github-oidc.sh # one-time GitHub OIDC provider + IAM role setup
└── .github/workflows/
    ├── terraform-validation.yml # fmt + validate on PR/push
    ├── terraform-pr.yml         # lint, Trivy scan, plan + PR comment
    └── terraform-apply.yml      # plan + apply on push to main
```

## Prerequisites

Install the following on the machine that will run Terraform:

- Terraform (>= 1.6.0)
- AWS CLI
- kubectl
- jq (only needed by `scripts/bootstrap-github-oidc.sh`)

Make sure your AWS credentials are available:

```bash
aws configure
```

## Quick start (dev)

### 1. Change to the environment directory

```bash
cd /path/to/platform-infrastructure/environments/dev
```

### 2. Review the environment values

Edit the values in [environments/dev/terraform.tfvars](environments/dev/terraform.tfvars). The cluster defaults to `prod-platform` — rename it if you want a dev-specific name. Set `admin_role_arn` to an IAM role ARN you can assume so it is mapped to `system:masters` via an EKS access entry.

### 3. Bootstrap the Terraform backend (first run only)

The state bucket must exist before the dev backend can initialize. Create it from the dedicated bootstrap configuration:

```bash
cd /path/to/platform-infrastructure/environments/bootstrap
terraform init
terraform apply
```

This creates the `my-platform-terraform-state-use1` S3 bucket (versioned, encrypted, private). Then initialize the dev environment:

```bash
cd ../dev
terraform init -reconfigure
```

### 4. Create the platform

```bash
terraform apply
```

This provisions the VPC, EKS cluster, node group, IRSA roles, and all Helm add-ons (including Argo CD). Expect it to take 15–20 minutes.

### 5. Connect to the cluster

After the apply finishes, configure kubectl (use your actual cluster name):

```bash
aws eks update-kubeconfig --region us-east-1 --name prod-platform
```

Verify that the cluster and nodes are healthy:

```bash
kubectl get nodes
kubectl get pods -n kube-system
```

## Production

The `production` environment uses the same modules with its own state backend and tags. Apply it the same way:

```bash
cd /path/to/platform-infrastructure/environments/production
terraform init -reconfigure
terraform apply
```

The `staging` environment follows the same pattern. State keys, IAM access entries, and tag values differ per environment. See [docs/production-setup.md](docs/production-setup.md) for the full production runbook — prerequisites, the deployment approval gate, and the dev → staging → production promotion flow.

## CI/CD

Three GitHub Actions workflows operate on `.tf` changes:

| Workflow | Trigger | What it does |
|---|---|---|
| `terraform-validation.yml` | PRs and pushes touching `.tf`/`.tfvars` | `terraform fmt` + `terraform validate` (dev) |
| `terraform-pr.yml` | Pull requests touching environments/modules | fmt + validate per environment, Trivy IaC scan (HIGH/CRITICAL), `terraform plan` with an inline PR comment |
| `terraform-apply.yml` | Push to `main` touching environments/modules (or `workflow_dispatch`) | detects changed environments, plans, uploads the plan artifact, and applies it — gated per environment by GitHub environment protection rules |

### One-time OIDC setup for GitHub Actions

The workflows assume an IAM role via GitHub's OIDC provider. Run the idempotent setup script once (safe to re-run):

```bash
./scripts/bootstrap-github-oidc.sh
```

It creates the OIDC provider and a `GithubActionsDeployer` role that trusts the repository, then attaches a policy granting Terraform state and lock access. After it completes, set the repo variable:

```bash
gh variable set AWS_OIDC_ROLE_ARN --repo <org>/platform-infrastructure --body "<role-arn>"
```

The workflows also expect:

- `TF_STATE_BUCKET` — repo secret (the S3 state bucket name)
- `AWS_OIDC_ROLE_ARN` — repo variable (from the script above)

## Useful follow-up commands

- View the Terraform state:

```bash
terraform state list
```

- Destroy the platform when needed:

```bash
terraform destroy
```

- Check the EBS CSI controller deployment:

```bash
kubectl get deployment ebs-csi-controller -n kube-system
```

- Check the installed Helm releases:

```bash
helm list -A
```

- Retrieve the Argo CD server endpoint (internal NLB) and initial admin password:

```bash
kubectl get svc argocd-server -n argocd
kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath="{.data.password}" | base64 -d; echo
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

Both run `terraform fmt` and `terraform validate` against the dev environment and require Terraform to be installed locally. CI runs the same checks on every PR.

## Next steps

The platform ships with Argo CD already installed (internal NLB, IRSA provisioned for the application controller). Next steps to build on top of it:

- Create a GitOps application repository and register it as an Argo CD Application.
- Access Argo CD via `kubectl port-forward svc/argocd-server -n argocd 8080:443` and log in with the admin password above.
- Add AWS Secrets Manager / SSM parameter secrets via External Secrets Operator.

## Documentation

- [docs/ci-cd.md](docs/ci-cd.md) — pipeline runbook: PR evidence → controlled apply, workflow sequencing, local reproduction, required repository configuration.
- [docs/production-setup.md](docs/production-setup.md) — production runbook: prerequisites, initial deployment, the GitHub environment approval gate, and the dev → staging → production promotion flow.
