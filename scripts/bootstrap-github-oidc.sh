#!/usr/bin/env bash
# bootstrap-github-oidc.sh
#
# Idempotent setup of the GitHub Actions OIDC provider + assumable IAM role.
# Safe to re-run: checks for existing resources before creating anything.
#
# Usage:
#   ./bootstrap-github-oidc.sh
#
# Requires: aws cli (configured with sufficient IAM perms), jq

set -euo pipefail

AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
GITHUB_ORG="jaybeedevx"
GITHUB_REPO="platform-infrastructure"
ROLE_NAME="GithubActionsDeployer"
OIDC_URL="token.actions.githubusercontent.com"
OIDC_PROVIDER_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_URL}"
# GitHub's current intermediate CA thumbprint. Verify against your account
# if this script ever needs to create the provider fresh -- do not assume
# this value is still correct without checking, GitHub has rotated it before.
THUMBPRINT="6938fd4d98bab03faadb97b34396831e3780aea1"

echo "== Account: ${AWS_ACCOUNT_ID} =="

# ---------------------------------------------------------------------------
# 1. OIDC Provider (idempotent: skip if it already exists)
# ---------------------------------------------------------------------------
if aws iam get-open-id-connect-provider \
    --open-id-connect-provider-arn "${OIDC_PROVIDER_ARN}" >/dev/null 2>&1; then
  echo "OIDC provider already exists: ${OIDC_PROVIDER_ARN}"
else
  echo "Creating OIDC provider..."
  aws iam create-open-id-connect-provider \
    --url "https://${OIDC_URL}" \
    --client-id-list "sts.amazonaws.com" \
    --thumbprint-list "${THUMBPRINT}"
  echo "Created: ${OIDC_PROVIDER_ARN}"
fi

# ---------------------------------------------------------------------------
# 2. Trust policy (wildcarded sub to tolerate GitHub's immutable-ID format:
#    repo:OWNER@ORG_ID/REPO@REPO_ID:pull_request)
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
            "repo:${GITHUB_ORG}*/${GITHUB_REPO}*:pull_request",
            "repo:${GITHUB_ORG}*/${GITHUB_REPO}*:ref:refs/heads/*",
            "repo:${GITHUB_ORG}*/${GITHUB_REPO}*:ref:refs/tags/*"
          ]
        }
      }
    }
  ]
}
EOF

# ---------------------------------------------------------------------------
# 3. IAM Role (create if missing, otherwise just update trust policy)
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
    --tags Key=ManagedBy,Value=bootstrap-script Key=Purpose,Value=github-actions-ci-cd
fi

rm -f "${TRUST_POLICY_FILE}"

# ---------------------------------------------------------------------------
# 4. Inline permissions policy: Terraform state (S3 + DynamoDB lock) access
# ---------------------------------------------------------------------------
# The Terraform backend uses S3 native locking (use_lockfile = true), so this
# role only needs object-level access to the state bucket -- no DynamoDB table.
STATE_BUCKET="my-platform-terraform-state-use1"
INLINE_POLICY_NAME="terraform-state-access"

INLINE_POLICY_FILE="$(mktemp)"
cat > "${INLINE_POLICY_FILE}" <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:ListBucket"
            ],
            "Resource": "arn:aws:s3:::${STATE_BUCKET}"
        },
        {
            "Effect": "Allow",
            "Action": [
                "s3:GetObject",
                "s3:PutObject",
                "s3:DeleteObject"
            ],
            "Resource": "arn:aws:s3:::${STATE_BUCKET}/*"
        },
        {
            "Effect": "Allow",
            "Action": "iam:GetRole",
            "Resource": "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ROLE_NAME}"
        }
    ]
}
EOF

echo "Attaching/updating inline policy: ${INLINE_POLICY_NAME}"
aws iam put-role-policy \
  --role-name "${ROLE_NAME}" \
  --policy-name "${INLINE_POLICY_NAME}" \
  --policy-document "file://${INLINE_POLICY_FILE}"

rm -f "${INLINE_POLICY_FILE}"

ROLE_ARN="$(aws iam get-role --role-name "${ROLE_NAME}" --query 'Role.Arn' --output text)"

echo ""
echo "== Done =="
echo "OIDC provider: ${OIDC_PROVIDER_ARN}"
echo "Role ARN:      ${ROLE_ARN}"
echo "Inline policy: ${INLINE_POLICY_NAME} (Terraform state S3 access only)"
echo ""
echo "NOTE: this role can now read/write your Terraform state (S3 native locking),"
echo "but has NO permissions yet to actually manage EKS/VPC/etc. resources."
echo "Add further scoped statements (or attach managed/customer policies) for"
echo "whatever your workflows provision -- do not attach AdministratorAccess."
echo ""
echo "Next step, set as a repo variable:"
echo "  gh variable set AWS_OIDC_ROLE_ARN --repo ${GITHUB_ORG}/${GITHUB_REPO} --body \"${ROLE_ARN}\""