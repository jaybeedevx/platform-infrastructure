#!/usr/bin/env bash
# bootstrap-ecr-push-role.sh
#
# Idempotent setup of the IAM role that lets GitHub Actions push webapp images
# to Amazon ECR. This is the role referenced by the `images` job in the
# platform-config repo's .github/workflows/webapp.yml (AWS_ROLE_TO_ASSUME).
#
# It differs from bootstrap-github-oidc.sh in one important way: the trust
# policy is scoped to the **platform-config** repo, not platform-infrastructure.
# The role has NO Terraform/state permissions -- it can only push images to the
# two webapp ECR repositories (and read their metadata).
#
# The OIDC provider (token.actions.githubusercontent.com) is shared and is
# created/owned by bootstrap-github-oidc.sh, so this script only creates the
# role; it does not touch the provider.
#
# Safe to re-run: checks for existing role, rewrites trust + inline policy
# idempotently.
#
# Usage:
#   ./bootstrap-ecr-push-role.sh
#
# Requires: aws cli (configured with iam:CreateRole / iam:PutRolePolicy),
#           jq. Assumes the OIDC provider already exists (see bootstrap-github-oidc.sh).

set -euo pipefail

AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
AWS_REGION="us-east-1"

# The repo whose GitHub Actions workflows will assume this role to push images.
GITHUB_ORG="jaybeedevx"
GITHUB_REPO="platform-config"

ROLE_NAME="GithubActionsECRPush"
ROLE_POLICY_NAME="ecr-webapp-push"

OIDC_URL="token.actions.githubusercontent.com"
OIDC_PROVIDER_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_URL}"

# The two ECR repos this role may push to.
ECR_REPOS=(
  "arn:aws:ecr:${AWS_REGION}:${AWS_ACCOUNT_ID}:repository/webapp-backend"
  "arn:aws:ecr:${AWS_REGION}:${AWS_ACCOUNT_ID}:repository/webapp-frontend"
)

echo "== Account: ${AWS_ACCOUNT_ID} | Repo: ${GITHUB_ORG}/${GITHUB_REPO} =="

# Sanity: the OIDC provider must already exist.
if ! aws iam get-open-id-connect-provider \
    --open-id-connect-provider-arn "${OIDC_PROVIDER_ARN}" >/dev/null 2>&1; then
  echo "ERROR: OIDC provider not found: ${OIDC_PROVIDER_ARN}" >&2
  echo "Run ./bootstrap-github-oidc.sh first to create it." >&2
  exit 1
fi
echo "OIDC provider present: ${OIDC_PROVIDER_ARN}"

# ---------------------------------------------------------------------------
# Trust policy -- scoped to the platform-config repo. See bootstrap-github-oidc.sh
# for why both plain and ID-qualified `sub` patterns are listed.
# ---------------------------------------------------------------------------
TRUST_POLICY_FILE="$(mktemp)"
cat > "${TRUST_POLICY_FILE}" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "${OIDC_PROVIDER_ARN}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_URL}:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "${OIDC_URL}:sub": [
            "repo:${GITHUB_ORG}/${GITHUB_REPO}:*",
            "repo:${GITHUB_ORG}@*/${GITHUB_REPO}@*:*"
          ]
        }
      }
    }
  ]
}
EOF

# ---------------------------------------------------------------------------
# IAM role -- create if missing, else refresh the trust policy.
# ---------------------------------------------------------------------------
if aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
  echo "Role already exists: ${ROLE_NAME} -- updating trust policy"
  aws iam update-assume-role-policy \
    --role-name "${ROLE_NAME}" \
    --policy-document "file://${TRUST_POLICY_FILE}"
else
  echo "Creating role: ${ROLE_NAME}"
  aws iam create-role \
    --role-name "${ROLE_NAME}" \
    --assume-role-policy-document "file://${TRUST_POLICY_FILE}" \
    --max-session-duration 3600 \
    --tags Key=ManagedBy,Value=bootstrap-script Key=Purpose,Value=github-actions-ecr-push
fi
rm -f "${TRUST_POLICY_FILE}"

# ---------------------------------------------------------------------------
# Inline policy -- ECR push for the webapp repos only (least privilege).
# ---------------------------------------------------------------------------
ECR_REPO_RESOURCES="$(printf '%s\n' "${ECR_REPOS[@]}" | python3 -c "import sys,json; print(', '.join(json.dumps(l) for l in sys.stdin.read().splitlines() if l))")"

INLINE_POLICY_FILE="$(mktemp)"
cat > "${INLINE_POLICY_FILE}" <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "EcrAuthorization",
            "Effect": "Allow",
            "Action": "ecr:GetAuthorizationToken",
            "Resource": "*"
        },
        {
            "Sid": "EcrWebappPush",
            "Effect": "Allow",
            "Action": [
                "ecr:PutImage",
                "ecr:BatchGetImage",
                "ecr:BatchCheckLayerAvailability",
                "ecr:GetDownloadUrlForLayer",
                "ecr:InitiateLayerUpload",
                "ecr:UploadLayerPart",
                "ecr:CompleteLayerUpload"
            ],
            "Resource": [
                ${ECR_REPO_RESOURCES}
            ]
        }
    ]
}
EOF

echo "Attaching/updating inline policy: ${ROLE_POLICY_NAME}"
aws iam put-role-policy \
  --role-name "${ROLE_NAME}" \
  --policy-name "${ROLE_POLICY_NAME}" \
  --policy-document "file://${INLINE_POLICY_FILE}"

rm -f "${INLINE_POLICY_FILE}"

ROLE_ARN="$(aws iam get-role --role-name "${ROLE_NAME}" --query 'Role.Arn' --output text)"

echo ""
echo "== Done =="
echo "Role ARN:             ${ROLE_ARN}"
echo "Inline policy:        ${ROLE_POLICY_NAME} (ECR push for webapp repos)"
echo ""
echo "Set it as the platform-config repo secret so the images job can assume it:"
echo "  gh secret set AWS_ROLE_TO_ASSUME --repo ${GITHUB_ORG}/${GITHUB_REPO} --body \"${ROLE_ARN}\""
