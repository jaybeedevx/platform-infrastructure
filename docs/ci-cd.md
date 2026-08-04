# CI/CD Pipeline

This document explains how the GitHub Actions workflows turn a change to this repository into deployed infrastructure. The mental model:

- **PR workflows produce evidence.** A pull request that touches Terraform files runs validation, a security scan, and a `terraform plan` whose output is posted on the PR for reviewers to read.
- **Apply workflows execute under control.** Pushes to `main` (i.e. after a PR merges) run `terraform apply` against the *saved* plan, gated behind GitHub environment protection rules.

Nobody applies against shared infrastructure from a laptop. The plan output is a public artifact tied to a specific commit, the approval gate is auditable, and apply uses a saved plan rather than a fresh one.

## Workflows

| Workflow | Trigger | Jobs |
|---|---|---|
| [`terraform-validation.yml`](../.github/workflows/terraform-validation.yml) | PRs and pushes touching any `.tf`/`.tfvars` | `terraform fmt` + `terraform validate` (dev) |
| [`terraform-pr.yml`](../.github/workflows/terraform-pr.yml) | PRs touching `environments/**`, `modules/**`, or the workflow itself | Lint → Security → Plan (per environment, with PR comment) |
| [`terraform-apply.yml`](../.github/workflows/terraform-apply.yml) | Push to `main` touching `environments/**`, `modules/**`, or the workflow itself; also `workflow_dispatch` | Detect → Plan → Apply (per environment) |

Environments are `dev`, `staging`, and `production`, matching the directories under `environments/`. GitHub environments with the same names hold the deployment protection rules.

## The PR workflow (evidence collection)

`terraform-pr.yml` runs three jobs, in order:

1. **Lint** (`matrix: dev, staging, production`) — runs `terraform fmt -check -recursive` to catch formatting drift, then `terraform init -backend=false` and `terraform validate` to confirm the configuration is structurally sound. `-backend=false` skips backend/state initialization — you don't need real state access just to validate syntax and type constraints.
2. **Security** — runs [Trivy](https://aquasecurity.github.io/trivy/) as an IaC scanner over `environments/`, failing on HIGH/CRITICAL findings (`exit-code: 1`). This is the cheap static-analysis layer; it catches configuration-level security issues before they reach infrastructure.
3. **Plan** (`needs: [lint, security]`) — runs `terraform plan -out=plan.tfplan`, captures the output, and posts it as a comment on the PR with a per-environment marker (`<!-- terraform-pr-plan-<env> -->`). The comment is updated in place on subsequent pushes.

Two details worth knowing:

- The plan step uses `continue-on-error: true` so the PR comment always gets posted — even when the plan fails — and a separate step fails the job if the plan did not succeed. Reviewers always see *something*.
- The `concurrency` block keys on the branch name with `cancel-in-progress: true`: two quick pushes cancel the first run rather than planning a stale commit.
- The `permissions` block requests `pull-requests: write` so the workflow can post that comment.

## The apply workflow (controlled execution)

`terraform-apply.yml` runs on pushes to `main`, after a PR merges.

1. **Detect** — uses `dorny/paths-filter` to figure out which environments actually changed, then emits a JSON list (e.g. `["dev","production"]`). If a module under `modules/**` changed, all three environments are targeted. `workflow_dispatch` lets you pick a single environment manually.
2. **Plan** (one job per detected environment) — configures AWS credentials via OIDC, runs `terraform plan -detailed-exitcode`, and distinguishes "no changes" (exit `0`) from "changes detected" (exit `2`). Only when changes exist is the plan uploaded as a build artifact (`tfplan-<env>`, 5-day retention).
3. **Apply** (one job per detected environment) — `needs: [detect, plan]`. It:
   - declares `environment: ${{ matrix.env }}`, which ties into GitHub's environment protection rules — a required-reviewer approval pauses the job here,
   - downloads the plan artifact with `continue-on-error: true` and checks it actually exists (`plan_exists`), so an environment with no changes is skipped rather than re-planned,
   - runs `terraform apply -auto-approve plan.tfplan` against the **saved** plan — so what gets applied is exactly what was planned and reviewed, not a re-plan that might include intervening changes.

The `-auto-approve` flag is safe here because two gates already passed: a human approved the PR that produced the code, and (where configured) a human approved the environment deployment. A per-environment `concurrency` group (`terraform-apply-<env>`, `cancel-in-progress: false`) prevents parallel applies to the same state.

## Required repository configuration

The workflows assume the following are configured in the GitHub repo settings:

| Setting | Type | Used by | Purpose |
|---|---|---|---|
| `AWS_OIDC_ROLE_ARN` | repository **variable** | `terraform-pr.yml`, `terraform-apply.yml` | IAM role to assume via OIDC (`vars.AWS_OIDC_ROLE_ARN`) |
| `TF_STATE_BUCKET` | repository **secret** | `terraform-pr.yml`, `terraform-apply.yml` | S3 state bucket name (`secrets.TF_STATE_BUCKET`) |
| `dev` / `staging` / `production` | GitHub **environments** | `terraform-apply.yml` | Deployment protection rules (required reviewers etc.) |

One-time OIDC setup, run once against your AWS account:

```bash
./scripts/bootstrap-github-oidc.sh
gh variable set AWS_OIDC_ROLE_ARN --repo <org>/platform-infrastructure --body "$(aws iam get-role --role-name GithubActionsDeployer --query 'Role.Arn' --output text)"
gh secret set TF_STATE_BUCKET --repo <org>/platform-infrastructure --body my-platform-terraform-state-use1
```

See [production-setup.md](production-setup.md) for the environment-protection configuration and the promotion flow.

## Reproducing CI locally

You don't need to push a PR to test what CI tests. From an environment directory, run the same commands the lint job runs:

```bash
cd environments/dev
terraform fmt -check -recursive
terraform init -backend=false
terraform validate
```

Or with OpenTofu:

```bash
cd environments/dev
tofu fmt -check -recursive
tofu init -backend=false
tofu validate
```

The security scan needs Trivy installed locally, but format + validate cover the most common CI failures. The plan step is what you'd already run in development: `terraform plan` from the environment directory, which requires valid AWS credentials and access to the S3 state bucket.
