#!/bin/bash
# Destroy the gateway: the app root module first, then foundation. Each destroy
# plan is shown for review and applied only after confirmation; --auto-approve
# skips the review.
#
#   deploy/undeploy.sh [--auto-approve]
#
# Deletion protection is respected, never disabled here: with
# deletion_protection = true (the default) the database refuses to be destroyed
# and buckets are kept. To really remove everything, take a backup, set
# deletion_protection = false in deploy/terraform.tfvars, run deploy/deploy.sh,
# then run this script again. The Terraform state bucket is always kept.
#
# Prerequisites: Terraform >= 1.10, the AWS CLI and jq.
# Nothing secret is read from or printed by this script.
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
[ -f "$TFVARS" ] || { echo "Missing ${TFVARS} (the same file the deploy used)" >&2; exit 1; }

REGION="${AWS_REGION:-$(aws configure get region || true)}"
[ -n "$REGION" ] || { echo "No region: set AWS_REGION or configure a default region" >&2; exit 1; }
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
TF_STATE_BUCKET="${TF_STATE_BUCKET:-litellm-gateway-tfstate-${ACCOUNT_ID}-${REGION}}"

aws s3api head-bucket --bucket "$TF_STATE_BUCKET" 2>/dev/null \
  || { echo "State bucket ${TF_STATE_BUCKET} not found: nothing to undeploy (set TF_STATE_BUCKET if it has a custom name)" >&2; exit 1; }

init() { # dir state-key
  terraform -chdir="$1" init -input=false -reconfigure \
    -backend-config="bucket=${TF_STATE_BUCKET}" \
    -backend-config="key=$2" \
    -backend-config="region=${REGION}" \
    -backend-config="encrypt=true" \
    -backend-config="use_lockfile=true" >/dev/null
}

plan_and_destroy() { # label dir extra-var-file...
  local label="$1" dir="$2" plan_file
  shift 2
  local var_files=(-var-file "$TFVARS")
  local extra
  for extra in "$@"; do
    var_files+=(-var-file "$extra")
  done

  plan_file="$(mktemp "${TMPDIR:-/tmp}/${label}-destroy.tfplan.XXXXXX")"
  echo ""
  echo "=== ${label}: destroy plan ==="
  terraform -chdir="$dir" plan -destroy -input=false "${var_files[@]}" -out="$plan_file"

  if [ "$AUTO_APPROVE" != true ]; then
    local answer
    read -r -p "Destroy ${label} as planned above? Only 'yes' destroys: " answer
    if [ "$answer" != "yes" ]; then
      echo "Stopped: ${label} was not destroyed." >&2
      rm -f "$plan_file"
      exit 1
    fi
  fi

  echo "=== ${label}: destroy ==="
  if ! terraform -chdir="$dir" apply -input=false "$plan_file"; then
    rm -f "$plan_file"
    echo "" >&2
    echo "Destroying ${label} failed. If the error mentions deletion protection:" >&2
    echo "take a backup, set deletion_protection = false in ${TFVARS}," >&2
    echo "run deploy/deploy.sh, then run this script again." >&2
    exit 1
  fi
  rm -f "$plan_file"
}

export AWS_REGION="$REGION"

# App first: it is destroyable against a living foundation at any time.
init "$APP_DIR" "app.tfstate"
mkdir -p "$GEN_DIR"
FOUNDATION_OUTPUTS="${GEN_DIR}/foundation-outputs.tfvars.json"
init "$FOUNDATION_DIR" "foundation.tfstate"
terraform -chdir="$FOUNDATION_DIR" output -json \
  | jq 'with_entries(.value |= .value)' > "$FOUNDATION_OUTPUTS"
plan_and_destroy "app" "$APP_DIR" "$FOUNDATION_OUTPUTS"

plan_and_destroy "foundation" "$FOUNDATION_DIR"

echo ""
echo "Done. The Terraform state bucket ${TF_STATE_BUCKET} is kept; delete it manually if wanted."
