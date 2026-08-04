# Production environment values.
# Before applying:
#   - set admin_role_arn to an IAM role you can assume (mapped to system:masters via an EKS access entry)
#   - make sure the S3 state bucket exists (see environments/bootstrap)
aws_region       = "us-east-1"
cluster_name     = "prod-platform"
cluster_version  = "1.36"
admin_role_arn   = "" # REQUIRED: e.g. "arn:aws:iam::123456789012:role/admins"
enable_flow_logs = true
