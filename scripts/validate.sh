#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

terraform fmt -check -recursive

cd environments/dev
terraform init -backend=false -input=false
terraform validate
