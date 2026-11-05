#!/bin/bash
# Sourced by deploy.sh and teardown.sh: prerequisites, the example's settings
# from terraform/terraform.tfvars, the gateway's foundation outputs, the
# Terraform backend (the example's state lives in the gateway deployment's
# state bucket under examples/eks/<name>.tfstate) and the kubectl context
# guard. Override the bucket with TF_STATE_BUCKET, the region with AWS_REGION,
# the foundation outputs file with FOUNDATION_OUTPUTS.

EXAMPLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "${EXAMPLE_DIR}/../.." && pwd)"
TF_DIR="${EXAMPLE_DIR}/terraform"
TFVARS="${TF_DIR}/terraform.tfvars"
# shellcheck disable=SC2034 # used by the scripts that source this file
RENDER=(python3 -I "${EXAMPLE_DIR}/scripts/render.py")

die() {
  echo "Error: $*" >&2
  exit 1
}

for tool in terraform aws jq kubectl python3; do
  command -v "$tool" >/dev/null || die "missing prerequisite: $tool"
done
[ -f "$TFVARS" ] || die "missing ${TFVARS} (copy terraform.tfvars.example and edit it)"

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
[ -n "$REGION" ] || die "set AWS_REGION to the gateway's region."
export AWS_REGION="$REGION"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/llmgw-eks.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

# name, deployment_name and cluster_name from the tfvars, read by Terraform
# itself (no regex over HCL) in a scratch module declaring only them.
read_settings() {
  local tmp
  tmp="$(mktemp -d "${WORK_DIR}/tfvars.XXXXXX")"
  cat >"${tmp}/main.tf" <<'EOF'
variable "name" {
  type    = string
  default = "llmgw-eks"
}
variable "deployment_name" {
  type    = string
  default = ""
}
variable "cluster_name" {
  type    = string
  default = ""
}
EOF
  printf 'var.name\nvar.deployment_name\nvar.cluster_name\n' |
    terraform -chdir="$tmp" console -var-file="$TFVARS" 2>/dev/null | sed -n 's/^"\(.*\)"$/\1/p'
}
SETTINGS="$(read_settings)" || true
NAME="$(sed -n 1p <<<"$SETTINGS")"
DEPLOYMENT_NAME="$(sed -n 2p <<<"$SETTINGS")"
CLUSTER_NAME="$(sed -n 3p <<<"$SETTINGS")"
[[ "$NAME" =~ ^[a-z][a-z0-9-]{2,19}$ ]] || die "name is invalid in ${TFVARS}"
[[ "$DEPLOYMENT_NAME" =~ ^[a-z][a-z0-9-]{0,19}$ ]] || die "deployment_name is missing or invalid in ${TFVARS}"
[[ "$CLUSTER_NAME" =~ ^[0-9A-Za-z][A-Za-z0-9_-]{0,99}$ ]] || die "cluster_name is missing or invalid in ${TFVARS}"

# The foundation outputs deploy/deploy.sh wrote for this gateway deployment.
FOUNDATION_OUTPUTS="${FOUNDATION_OUTPUTS:-${REPO_ROOT}/deploy/.generated/${DEPLOYMENT_NAME}-foundation-outputs.tfvars.json}"

# The two foundation values the example's Terraform takes (kms_key_arn is
# absent when the gateway uses AWS-managed keys).
FOUNDATION_TFVARS="${WORK_DIR}/foundation.tfvars.json"
write_foundation_tfvars() {
  [ -f "$FOUNDATION_OUTPUTS" ] || die "missing ${FOUNDATION_OUTPUTS}: run deploy/deploy.sh for the gateway first, or set FOUNDATION_OUTPUTS."
  jq -e '{vpc_cidr} + (if .kms_key_arn then {kms_key_arn} else {} end) | select(.vpc_cidr != null)' \
    "$FOUNDATION_OUTPUTS" >"$FOUNDATION_TFVARS" || die "${FOUNDATION_OUTPUTS} has no vpc_cidr."
}

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
TF_STATE_BUCKET="${TF_STATE_BUCKET:-litellm-gateway-tfstate-${ACCOUNT_ID}-${REGION}}"
aws s3api head-bucket --bucket "$TF_STATE_BUCKET" --expected-bucket-owner "$ACCOUNT_ID" >/dev/null 2>&1 ||
  die "state bucket ${TF_STATE_BUCKET} not found or not owned by ${ACCOUNT_ID}; set TF_STATE_BUCKET."

terraform -chdir="$TF_DIR" init -input=false -reconfigure \
  -backend-config="bucket=${TF_STATE_BUCKET}" \
  -backend-config="key=examples/eks/${NAME}.tfstate" \
  -backend-config="region=${REGION}" \
  -backend-config="encrypt=true" \
  -backend-config="use_lockfile=true" >/dev/null
echo "Terraform state: s3://${TF_STATE_BUCKET}/examples/eks/${NAME}.tfstate"

# kubectl must point at cluster_name: the current context's API server has to
# be the cluster's endpoint. Every later kubectl call is pinned to this context.
KUBE_CONTEXT=""
check_kube_context() {
  local want have
  KUBE_CONTEXT="$(kubectl config current-context 2>/dev/null)" || die "no current kubectl context; run: aws eks update-kubeconfig --name ${CLUSTER_NAME} --region ${REGION}"
  want="$(aws eks describe-cluster --name "$CLUSTER_NAME" --query cluster.endpoint --output text)" ||
    die "cannot describe EKS cluster ${CLUSTER_NAME} in ${REGION}."
  have="$(kubectl config view --minify --context "$KUBE_CONTEXT" -o jsonpath='{.clusters[0].cluster.server}')"
  [ "$(printf '%s' "${want%/}" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "${have%/}" | tr '[:upper:]' '[:lower:]')" ] ||
    die "kubectl context ${KUBE_CONTEXT} is not cluster ${CLUSTER_NAME}; run: aws eks update-kubeconfig --name ${CLUSTER_NAME} --region ${REGION}"
  echo "Cluster: ${CLUSTER_NAME} (kubectl context ${KUBE_CONTEXT})"
}

# kube <args...>: kubectl in the checked context and the example's namespace.
kube() {
  kubectl --context "$KUBE_CONTEXT" --namespace "$NAMESPACE" "$@"
}
