#!/usr/bin/env bash
# bootstrap-github-oidc.sh
#
# Idempotent setup of the GitHub Actions OIDC provider + per-environment
# assumable IAM deployer roles.
#
# The role a GitHub Actions job can assume is the SAME for every event type,
# because GitHub's OIDC `sub` claim cannot distinguish which environment a
# workflow_dispatch selected (a dispatch on `main` looks identical whether it
# deploys dev or prod). Per-environment isolation therefore comes from:
#   1. A DIFFERENT IAM role ARN per environment (this script),
#   2. Storing each ARN in a GitHub *environment* variable, not a repo var, so
#      only that environment's workflow run can read it, and
#   3. GitHub Environment protection rules (required reviewers / branch
#      restrictions) gating the `production` environment's apply job.
#
# Safe to re-run: checks for existing resources before creating anything, and
# rewrites the trust + inline policies idempotently.
#
# Usage:
#   ./bootstrap-github-oidc.sh [dev|staging|production]
#
# Requires: aws cli (configured with sufficient IAM perms), jq

set -euo pipefail

ENV="${1:-dev}"
case "${ENV}" in
  dev|staging|production) ;;
  *) echo "Invalid environment '${ENV}'. Use dev, staging, or production." >&2; exit 1 ;;
esac

# Cluster IAM roles created by terraform-aws-eks follow "<cluster>-*". Keep in
# sync with the `cluster_name` in each environment's terraform.tfvars so the
# PassRole grant below stays scoped (do not widen to role/*).
case "${ENV}" in
  dev)         CLUSTER_NAME="dev-platform" ;;
  staging)     CLUSTER_NAME="staging-platform" ;;
  production)  CLUSTER_NAME="prod-platform" ;;
esac

AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
AWS_REGION="us-east-1"
GITHUB_ORG="jaybeedevx"
GITHUB_REPO="platform-infrastructure"
ROLE_NAME="GithubActionsDeployer-${ENV}"
STATE_BUCKET="my-platform-terraform-state-use1"
OIDC_URL="token.actions.githubusercontent.com"
OIDC_PROVIDER_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_URL}"
# GitHub's current intermediate CA thumbprint. Verify against your account
# if this script ever needs to create the provider fresh -- do not assume
# this value is still correct without checking, GitHub has rotated it before.
THUMBPRINT="6938fd4d98bab03faadb97b34396831e3780aea1"

echo "== Environment: ${ENV} | Account: ${AWS_ACCOUNT_ID} =="

# ---------------------------------------------------------------------------
# 1. OIDC Provider (shared across environments; skip if it already exists)
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
# 2. Trust policy (identical per env -- see header comment for why)
# ---------------------------------------------------------------------------
# Wildcarded sub tolerates GitHub's immutable-ID format AND the legacy format,
# covering push, pull_request, and workflow_dispatch triggers alike.
#
# GitHub's current OIDC `sub` claim includes the org & repo database IDs, e.g.:
#   repo:jaybeedevx@201910675/platform-infrastructure@1308759777:ref:refs/heads/main
# The `@*` wildcard matches those IDs. Both the plain and ID-qualified
# patterns are listed so the policy works regardless of GitHub's token format.
write_trust_policy() {
  local file="$1"
  cat > "${file}" <<EOF
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
}

TRUST_POLICY_FILE="$(mktemp)"
write_trust_policy "${TRUST_POLICY_FILE}"

# ---------------------------------------------------------------------------
# 3. IAM Role (per environment; create if missing, else refresh trust policy)
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
    --tags Key=ManagedBy,Value=bootstrap-script Key=Purpose,Value=github-actions-ci-cd Key=Environment,Value="${ENV}"
fi

rm -f "${TRUST_POLICY_FILE}"

# ---------------------------------------------------------------------------
# 4. Inline policy: Terraform state + the EKS/VPC/IAM resources this env
#    provisions. Scoped per environment: object access is limited to the
#    env's own state key, and PassRole to the cluster/IRSA role prefixes.
#    ListBucket is intentionally bucket-wide: terraform init lists the bucket
#    ROOT (not the env prefix) to discover workspaces, so an s3:prefix
#    condition there breaks init. ListBucket only exposes key names, not
#    contents -- the env isolation comes from the object-level statements.
# ---------------------------------------------------------------------------
INLINE_POLICY_NAME="terraform-deployer"
INLINE_POLICY_FILE="$(mktemp)"
cat > "${INLINE_POLICY_FILE}" <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "TerraformStateList",
            "Effect": "Allow",
            "Action": ["s3:ListBucket"],
            "Resource": "arn:aws:s3:::${STATE_BUCKET}"
        },
        {
            "Sid": "TerraformStateObjects",
            "Effect": "Allow",
            "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
            "Resource": "arn:aws:s3:::${STATE_BUCKET}/${ENV}/*"
        },
        {
            "Sid": "EksClusterAndNodeGroups",
            "Effect": "Allow",
            "Action": ["eks:*"],
            "Resource": "*"
        },
        {
            "Sid": "VpcEc2Resources",
            "Effect": "Allow",
            "Action": [
                "ec2:Describe*",
                "ec2:CreateVpc", "ec2:DeleteVpc", "ec2:ModifyVpc", "ec2:ModifyVpcAttribute",
                "ec2:CreateSubnet", "ec2:DeleteSubnet", "ec2:ModifySubnet", "ec2:ModifySubnetAttribute",
                "ec2:CreateInternetGateway", "ec2:DeleteInternetGateway",
                "ec2:AttachInternetGateway", "ec2:DetachInternetGateway",
                "ec2:CreateNatGateway", "ec2:DeleteNatGateway",
                "ec2:CreateRouteTable", "ec2:DeleteRouteTable",
                "ec2:AssociateRouteTable", "ec2:DisassociateRouteTable",
                "ec2:CreateRoute", "ec2:DeleteRoute", "ec2:ReplaceRoute",
                "ec2:CreateSecurityGroup", "ec2:DeleteSecurityGroup",
                "ec2:AuthorizeSecurityGroupIngress", "ec2:AuthorizeSecurityGroupEgress",
                "ec2:RevokeSecurityGroupIngress", "ec2:RevokeSecurityGroupEgress",
                "ec2:AllocateAddress", "ec2:ReleaseAddress",
                "ec2:AssociateAddress", "ec2:DisassociateAddress",
                "ec2:RunInstances", "ec2:TerminateInstances", "ec2:ModifyInstanceAttribute",
                "ec2:CreateLaunchTemplate", "ec2:DeleteLaunchTemplate", "ec2:ModifyLaunchTemplate",
                "ec2:CreateLaunchTemplateVersion", "ec2:DeleteLaunchTemplateVersions",
                "ec2:CreateVolume", "ec2:DeleteVolume", "ec2:AttachVolume", "ec2:DetachVolume",
                "ec2:CreateKeyPair", "ec2:DeleteKeyPair",
                "ec2:CreateNetworkInterface", "ec2:DeleteNetworkInterface",
                "ec2:AttachNetworkInterface", "ec2:DetachNetworkInterface",
                "ec2:ModifyNetworkInterfaceAttribute", "ec2:ResetNetworkInterfaceAttribute",
                "ec2:CreateVpcEndpoint", "ec2:DeleteVpcEndpoint", "ec2:ModifyVpcEndpoint",
                "ec2:CreateFlowLogs", "ec2:DeleteFlowLogs",
                "ec2:CreateTags", "ec2:DeleteTags"
            ],
            "Resource": "*"
        },
        {
            "Sid": "AutoscalingNodeGroups",
            "Effect": "Allow",
            "Action": [
                "autoscaling:CreateAutoScalingGroup", "autoscaling:UpdateAutoScalingGroup",
                "autoscaling:DeleteAutoScalingGroup",
                "autoscaling:CreateLaunchConfiguration", "autoscaling:DeleteLaunchConfiguration",
                "autoscaling:Describe*", "autoscaling:SetDesiredCapacity"
            ],
            "Resource": "*"
        },
        {
            "Sid": "KmsClusterEncryption",
            "Effect": "Allow",
            "Action": [
                "kms:CreateKey", "kms:ScheduleKeyDeletion", "kms:CancelKeyDeletion",
                "kms:DescribeKey", "kms:EnableKey", "kms:DisableKey", "kms:ListKeys",
                "kms:GetKeyPolicy", "kms:PutKeyPolicy",
                "kms:TagResource", "kms:UntagResource",
                "kms:CreateAlias", "kms:UpdateAlias", "kms:DeleteAlias", "kms:ListAliases",
                "kms:EnableKeyRotation", "kms:DisableKeyRotation", "kms:GetKeyRotationStatus"
            ],
            "Resource": "*"
        },
        {
            "Sid": "IamRolesPolicies",
            "Effect": "Allow",
            "Action": [
                "iam:GetRole", "iam:ListRoles",
                "iam:CreateRole", "iam:DeleteRole", "iam:UpdateRole", "iam:TagRole", "iam:UntagRole", "iam:ListRoleTags",
                "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:GetRolePolicy", "iam:ListRolePolicies",
                "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:ListAttachedRolePolicies",
                "iam:CreatePolicy", "iam:DeletePolicy", "iam:GetPolicy", "iam:ListPolicies",
                "iam:CreatePolicyVersion", "iam:DeletePolicyVersion", "iam:GetPolicyVersion", "iam:ListPolicyVersions",
                "iam:TagPolicy", "iam:UntagPolicy", "iam:ListPolicyTags",
                "iam:CreateInstanceProfile", "iam:DeleteInstanceProfile", "iam:GetInstanceProfile",
                "iam:AddRoleToInstanceProfile", "iam:RemoveRoleFromInstanceProfile", "iam:ListInstanceProfiles",
                "iam:TagInstanceProfile", "iam:UntagInstanceProfile", "iam:ListInstanceProfileTags"
            ],
            "Resource": "*"
        },
        {
            "Sid": "IamPassRoleClusterAndIrsa",
            "Effect": "Allow",
            "Action": "iam:PassRole",
            "Resource": [
                "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${CLUSTER_NAME}-*",
                "arn:aws:iam::${AWS_ACCOUNT_ID}:role/irsa-*"
            ]
        },
        {
            "Sid": "IamOidcProvider",
            "Effect": "Allow",
            "Action": [
                "iam:CreateOpenIDConnectProvider", "iam:DeleteOpenIDConnectProvider",
                "iam:UpdateOpenIDConnectProviderThumbprint", "iam:GetOpenIDConnectProvider",
                "iam:TagOpenIDConnectProvider", "iam:UntagOpenIDConnectProvider",
                "iam:ListOpenIDConnectProviderTags"
            ],
            "Resource": "*"
        },
        {
            "Sid": "IamServiceLinkedRoles",
            "Effect": "Allow",
            "Action": "iam:CreateServiceLinkedRole",
            "Resource": [
                "arn:aws:iam::*:role/aws-service-role/autoscaling.amazonaws.com/AWSServiceRoleForAutoScaling",
                "arn:aws:iam::*:role/aws-service-role/vpc-flow-logs.amazonaws.com/AWSServiceRoleForVPCFlowLogs"
            ]
        },
        {
            "Sid": "CloudWatchLogsControlPlane",
            "Effect": "Allow",
            "Action": [
                "logs:CreateLogGroup", "logs:DeleteLogGroup", "logs:PutRetentionPolicy",
                "logs:DescribeLogGroups", "logs:ListLogGroups",
                "logs:ListTagsForResource", "logs:TagResource", "logs:UntagResource"
            ],
            "Resource": "arn:aws:logs:${AWS_REGION}:${AWS_ACCOUNT_ID}:log-group:*"
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

# ---------------------------------------------------------------------------
# 5. Read-only role for Terraform plan jobs (shared across environments)
# ---------------------------------------------------------------------------
# PR and apply-plan jobs only need to READ the current state + resources, so
# they get a separate, read-only role instead of the full deployer policy.
RO_ROLE_NAME="GithubActionsReadOnly"
RO_POLICY_NAME="terraform-plan-read-only"

RO_TRUST_FILE="$(mktemp)"
write_trust_policy "${RO_TRUST_FILE}"

if aws iam get-role --role-name "${RO_ROLE_NAME}" >/dev/null 2>&1; then
  echo "Role already exists: ${RO_ROLE_NAME} -- updating trust policy"
  aws iam update-assume-role-policy \
    --role-name "${RO_ROLE_NAME}" \
    --policy-document "file://${RO_TRUST_FILE}"
else
  echo "Creating role: ${RO_ROLE_NAME}"
  aws iam create-role \
    --role-name "${RO_ROLE_NAME}" \
    --assume-role-policy-document "file://${RO_TRUST_FILE}" \
    --max-session-duration 3600 \
    --tags Key=ManagedBy,Value=bootstrap-script Key=Purpose,Value=github-actions-terraform-plan
fi
rm -f "${RO_TRUST_FILE}"

RO_POLICY_FILE="$(mktemp)"
cat > "${RO_POLICY_FILE}" <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "TerraformStateRead",
            "Effect": "Allow",
            "Action": ["s3:GetObject", "s3:ListBucket"],
            "Resource": [
                "arn:aws:s3:::${STATE_BUCKET}",
                "arn:aws:s3:::${STATE_BUCKET}/*"
            ]
        },
        {
            "Sid": "DescribeClusterResources",
            "Effect": "Allow",
            "Action": [
                "ec2:Describe*",
                "eks:Describe*", "eks:List*",
                "autoscaling:Describe*",
                "elasticloadbalancing:Describe*",
                "kms:Describe*", "kms:List*", "kms:GetKeyPolicy",
                "logs:DescribeLogGroups", "logs:DescribeLogStreams", "logs:ListLogGroups",
                "iam:GetRole", "iam:ListRoles",
                "iam:GetPolicy", "iam:ListPolicies", "iam:GetPolicyVersion", "iam:ListPolicyVersions",
                "iam:GetRolePolicy", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies",
                "iam:GetInstanceProfile", "iam:ListInstanceProfiles",
                "iam:GetOpenIDConnectProvider", "iam:ListOpenIDConnectProviders"
            ],
            "Resource": "*"
        }
    ]
}
EOF

echo "Attaching/updating inline policy: ${RO_POLICY_NAME}"
aws iam put-role-policy \
  --role-name "${RO_ROLE_NAME}" \
  --policy-name "${RO_POLICY_NAME}" \
  --policy-document "file://${RO_POLICY_FILE}"

rm -f "${RO_POLICY_FILE}"

RO_ROLE_ARN="$(aws iam get-role --role-name "${RO_ROLE_NAME}" --query 'Role.Arn' --output text)"

ROLE_ARN="$(aws iam get-role --role-name "${ROLE_NAME}" --query 'Role.Arn' --output text)"

echo ""
echo "== Done: ${ENV} =="
echo "OIDC provider:        ${OIDC_PROVIDER_ARN}"
echo "Deployer role ARN:    ${ROLE_ARN}"
echo "Deployer inline pol:  ${INLINE_POLICY_NAME} (Terraform state + EKS/VPC/IAM deploy)"
echo "Read-only plan role:  ${RO_ROLE_ARN}"
echo "Read-only inline pol: ${RO_POLICY_NAME} (read-only plan access)"
echo ""
echo "Set the DEPLOYER role ARN as a per-ENVIRONMENT variable (not a repo var)"
echo "so each environment's workflow run can only reach its own role:"
echo "  gh variable set AWS_OIDC_ROLE_ARN --repo ${GITHUB_ORG}/${GITHUB_REPO} --env ${ENV} --body \"${ROLE_ARN}\""
echo ""
echo "Set the READ-ONLY role ARN as a REPO-level variable (shared by plan jobs):"
echo "  gh variable set AWS_OIDC_READONLY_ROLE_ARN --repo ${GITHUB_ORG}/${GITHUB_REPO} --body \"${RO_ROLE_ARN}\""
echo ""
echo "Then gate the production apply with GitHub Environment protection rules"
echo "(required reviewers / main-branch restriction) in Settings > Environments."
echo ""
echo "Do NOT attach AdministratorAccess -- widen specific statements here if"
echo "Terraform reports a missing action, and re-run this script."
