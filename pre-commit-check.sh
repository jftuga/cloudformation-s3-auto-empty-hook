#!/bin/bash
set -euo pipefail
set -x

function check() {
  local cfn_file="$1"
  yamllint "${cfn_file}"
  cfn-lint -t "${cfn_file}"
  sam validate --lint -t "${cfn_file}"
  aws cloudformation validate-template --no-cli-pager --template-body "file://${cfn_file}"
}

check lambda-hook-infrastructure.yaml
check s3-bucket-resources.yaml

# check for trailing whitespace
echo
rg " $" -g="*sh" -g="*toml" -g="*md" -g="*yaml" -g="*py" || true
