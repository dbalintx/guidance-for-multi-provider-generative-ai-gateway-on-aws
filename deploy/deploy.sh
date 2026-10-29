#!/bin/bash
# Deploy or update the gateway: the foundation root module first, then app.
#
#   deploy/deploy.sh [--auto-approve]
#
# Inputs come from deploy/terraform.tfvars (copy terraform.tfvars.example; it
# documents every variable and which root module consumes it). Each plan is
# shown for review and applied only after confirmation; --auto-approve skips
# the review. Foundation outputs are wired into app via `terraform output
# -json` — app never reads foundation state directly.
#
# State lives in a versioned, encrypted, private S3 bucket with native S3
# locking. The bucket is created on first run (the fresh-account bootstrap
# step, see docs/fresh-account-notes.md); override its name with
# TF_STATE_BUCKET, the region with AWS_REGION.
#
# Prerequisites: Terraform >= 1.10, the AWS CLI and jq.
# Nothing secret is read from or printed by this script: secrets enter the
# stack as Secrets Manager ARNs only.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${SCRIPT_DIR}")"
FOUNDATION_DIR="${REPO_ROOT}/terraform/foundation"
APP_DIR="${REPO_ROOT}/terraform/app"
TFVARS="${SCRIPT_DIR}/terraform.tfvars"
GEN_DIR="${SCRIPT_DIR}/.generated"

AUTO_APPROVE=false
for arg in "$@"; do
  case "$arg" in
    --auto-approve) AUTO_APPROVE=true ;;
    *) echo "Usage: $0 [--auto-approve]" >&2; exit 2 ;;
  esac
done

for tool in terraform aws jq; do
  command -v "$tool" >/dev/null || { echo "Missing prerequisite: $tool" >&2; exit 1; }
done
[ -f "$TFVARS" ] || { echo "Missing ${TFVARS} (copy terraform.tfvars.example and edit it)" >&2; exit 1; }

REGION="${AWS_REGION:-$(aws configure get region || true)}"
[ -n "$REGION" ] || { echo "No region: set AWS_REGION or configure a default region" >&2; exit 1; }
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
TF_STATE_BUCKET="${TF_STATE_BUCKET:-litellm-gateway-tfstate-${ACCOUNT_ID}-${REGION}}"

# State bucket: versioned, encrypted, private, with native S3 state locking
# (use_lockfile). Creating it is the fresh-account bootstrap step.
if ! aws s3api head-bucket --bucket "$TF_STATE_BUCKET" 2>/dev/null; then
  echo "Creating Terraform state bucket ${TF_STATE_BUCKET} in ${REGION}"
  if [ "$REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$TF_STATE_BUCKET" --region "$REGION" >/dev/null
  else
    aws s3api create-bucket --bucket "$TF_STATE_BUCKET" --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION" >/dev/null
  fi
  aws s3api put-bucket-versioning --bucket "$TF_STATE_BUCKET" \
    --versioning-configuration Status=Enabled
  aws s3api put-bucket-encryption --bucket "$TF_STATE_BUCKET" \
    --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
  aws s3api put-public-access-block --bucket "$TF_STATE_BUCKET" \
    --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
else
  echo "Using Terraform state bucket ${TF_STATE_BUCKET}"
fi

init() { # dir state-key
  terraform -chdir="$1" init -input=false -reconfigure \
    -backend-config="bucket=${TF_STATE_BUCKET}" \
    -backend-config="key=$2" \
    -backend-config="region=${REGION}" \
    -backend-config="encrypt=true" \
    -backend-config="use_lockfile=true" >/dev/null
}

plan_and_apply() { # label dir extra-var-file...
  local label="$1" dir="$2" plan_file
  shift 2
  local var_files=(-var-file "$TFVARS")
  local extra
  for extra in "$@"; do
    var_files+=(-var-file "$extra")
  done

  plan_file="$(mktemp "${TMPDIR:-/tmp}/${label}.tfplan.XXXXXX")"
  echo ""
  echo "=== ${label}: plan ==="
  terraform -chdir="$dir" plan -input=false "${var_files[@]}" -out="$plan_file"

  if [ "$AUTO_APPROVE" != true ]; then
    local answer
    read -r -p "Apply the ${label} plan above? Only 'yes' applies: " answer
    if [ "$answer" != "yes" ]; then
      echo "Stopped: the ${label} plan was not applied." >&2
      rm -f "$plan_file"
      exit 1
    fi
  fi

  echo "=== ${label}: apply ==="
  terraform -chdir="$dir" apply -input=false "$plan_file"
  rm -f "$plan_file"
}

export AWS_REGION="$REGION"

init "$FOUNDATION_DIR" "foundation.tfstate"
plan_and_apply "foundation" "$FOUNDATION_DIR"

# Wire foundation outputs into app as plain input variables (names match 1:1).
# Null-valued outputs (e.g. kms_key_arn without a customer key) are omitted by
# `terraform output -json`; the matching app variables default to null.
mkdir -p "$GEN_DIR"
FOUNDATION_OUTPUTS="${GEN_DIR}/foundation-outputs.tfvars.json"
terraform -chdir="$FOUNDATION_DIR" output -json \
  | jq 'with_entries(.value |= .value)' > "$FOUNDATION_OUTPUTS"

init "$APP_DIR" "app.tfstate"
plan_and_apply "app" "$APP_DIR" "$FOUNDATION_OUTPUTS"

echo ""
echo "Done. Gateway URL (null until the ALB lands):"
terraform -chdir="$APP_DIR" output service_url
