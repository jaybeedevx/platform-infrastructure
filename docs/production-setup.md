# Production Setup

This is the runbook for standing up and operating the `production` environment. It covers the one-time prerequisites, the initial deployment, the CI/CD approval gate, and the dev → staging → production promotion flow.

## What production deploys

The `production` environment is the same stack as `dev`/`staging`, built from the shared `modules/`:

- VPC (3 AZs, NAT gateway) **with VPC flow logs enabled** (`enable_flow_logs = true`)
- EKS cluster `prod-platform` (Kubernetes 1.36), AL2023 managed node group (`t3.medium`, 2–9 nodes)
- OIDC provider + IRSA roles (EBS/EFS CSI, Load Balancer Controller, External Secrets, Argo CD)
- Helm add-ons: LB controller, EBS/EFS CSI drivers, Metrics Server, cert-manager, External Secrets, Argo CD (internal NLB)

## 1. One-time prerequisites

1. **AWS credentials** — valid, with permission to create VPC/EKS/IAM resources, on whatever machine or role runs the apply (`aws sts get-caller-identity` must succeed).
2. **Terraform state bucket** — created once by the bootstrap environment (versioned, encrypted, private):

   ```bash
   cd environments/bootstrap
   terraform init
   terraform apply
   ```

   This creates `my-platform-terraform-state-use1`. The same bucket holds state for all environments under distinct keys (`<env>/eks-foundation.tfstate` for local runs; `<env>/terraform.tfstate` for CI).
3. **Admin access role** — decide which IAM role is allowed to administer the cluster, and set its ARN:

   ```hcl
   # environments/production/terraform.tfvars
   admin_role_arn = "arn:aws:iam::123456789012:role/admins"
   ```

   The role is mapped to `system:masters` via an EKS access entry. If this is left empty, no admin access entry is created and you can only reach the cluster as the identity that created it.

## 2. Initial production deployment

```bash
cd environments/production
terraform init -reconfigure
terraform apply
```

Because flow logs are enabled in production, this also creates a CloudWatch log group (`/prod-platform/vpc-flow-logs`) and an IAM role to write them.

### Local apply vs. CI apply

- **Local** — state key `production/eks-foundation.tfstate`. Good for the initial build-out.
- **CI** — the apply workflow overrides the key to `production/terraform.tfstate`. Don't mix local and CI applies against the same environment: the state objects differ, and the two will not see each other's changes. Pick one and stick with it per environment (recommended: CI once the environment is established, local only for the initial creation or when CI is unavailable).

## 3. Configure the deployment approval gate

`terraform-apply.yml` declares `environment: ${{ matrix.env }}`, so each environment (`dev`, `staging`, `production`) is a GitHub Environment. Configure production protection so applies pause for review:

1. Repo → **Settings → Environments → New environment** → `production` (repeat for `dev` and `staging` if desired).
2. Under **Deployment branch protection**, restrict to `main` (the apply workflow only fires on `main`, but an explicit policy is defense in depth).
3. Under **Required reviewers**, add the people/teams whose approval is required before `terraform apply` runs.

When the apply job reaches the `environment` step, GitHub pauses execution and waits for that approval. This — combined with the PR approval that got the change onto `main` — is the human gate that makes `-auto-approve` on the apply step safe.

## 4. The promotion flow

Changes travel through the environments in order; the workflows handle each one independently:

1. **PR** → `terraform-pr.yml` lints, scans, and posts a `terraform plan` comment per environment (dev/staging/production).
2. **Merge to `main`** → `terraform-apply.yml` plans and applies **only the environments whose files changed** (or all three if `modules/**` changed). Each changed environment waits on its own GitHub-environment approval.
3. **Manual run** → `workflow_dispatch` lets you deploy a single environment by name without a code change (useful for a forced promotion).

## 5. Post-deployment verification

```bash
aws eks update-kubeconfig --region us-east-1 --name prod-platform
kubectl get nodes
kubectl get pods -n kube-system
kubectl get svc argocd-server -n argocd   # internal NLB endpoint
kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath="{.data.password}" | base64 -d; echo
```

## Operational notes

- **Flow-log IAM role** — the VPC module attaches the AWS-managed `CloudWatchLogsFullAccess` policy to the flow-log role. It's broader than strictly necessary; consider scoping it to the single log group if you tighten this later.
- **Destroying production** is destructive by design — `terraform destroy` in this directory deletes the cluster, VPC, and all add-on namespaces. There is no automated guard beyond the GitHub-environment approval gate; run it deliberately and only after confirming state is what you expect (`terraform state list`).
- **Terraform lock files** — `.terraform.lock.hcl` is gitignored in this repo. Consider committing it so provider versions are reproducible across machines and CI.
