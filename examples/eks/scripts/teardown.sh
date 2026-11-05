#!/bin/bash
# Remove the example: delete its Kubernetes namespace (pods, Job, Service,
# ConfigMaps, the Secret), then destroy its AWS resources (IAM role, Pod
# Identity association, request-log bucket and its logs). The cluster and the
# gateway are not touched.
#
#   AWS_REGION=<gateway region> scripts/teardown.sh [--auto-approve] [--skip-kubernetes]
#
# --skip-kubernetes destroys the AWS resources only (the cluster is already gone).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPROVE=()
SKIP_KUBERNETES=false
for arg in "$@"; do
  case "$arg" in
    --auto-approve) APPROVE=(-auto-approve) ;;
    --skip-kubernetes) SKIP_KUBERNETES=true ;;
    *) echo "Usage: $0 [--auto-approve] [--skip-kubernetes]" >&2; exit 2 ;;
  esac
done

# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

if [ "$SKIP_KUBERNETES" != true ]; then
  check_kube_context
  NAMESPACE="$(terraform -chdir="$TF_DIR" output -raw namespace 2>/dev/null)" ||
    die "no namespace in the example's Terraform state; nothing deployed? (use --skip-kubernetes to destroy the AWS resources only)"
  if [ ${#APPROVE[@]} -eq 0 ]; then
    read -r -p "Delete namespace ${NAMESPACE} and everything in it on cluster ${CLUSTER_NAME}? Only 'yes' deletes: " answer
    [ "$answer" = "yes" ] || die "stopped: nothing was deleted."
  fi
  kubectl --context "$KUBE_CONTEXT" delete namespace "$NAMESPACE" --ignore-not-found --wait=true
fi

# The variables only shape the plan, not what is destroyed: without the
# foundation outputs (gateway already removed) any valid vpc_cidr will do.
if [ -f "$FOUNDATION_OUTPUTS" ]; then
  write_foundation_tfvars
else
  echo '{"vpc_cidr": "10.0.0.0/16"}' >"$FOUNDATION_TFVARS"
fi
terraform -chdir="$TF_DIR" destroy -input=false -var-file="$TFVARS" -var-file="$FOUNDATION_TFVARS" ${APPROVE[@]+"${APPROVE[@]}"}

echo "Removed. If you admitted the cluster to the data stores, remove its security group from extra_data_ingress_security_group_ids and redeploy the gateway."
