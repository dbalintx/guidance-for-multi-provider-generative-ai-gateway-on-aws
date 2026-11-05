#!/bin/bash
# Deploy or update the gateway on an existing EKS cluster:
#
#   AWS_REGION=<gateway region> scripts/deploy.sh [--auto-approve]
#
# 1. terraform apply: the pods' IAM role and Pod Identity association, the
#    request-log bucket and the rendered LiteLLM config (shows the plan and
#    asks for confirmation unless --auto-approve);
# 2. renders the manifests (render.py) with the image pinned in
#    terraform/app/container.tf (IMAGE overrides it with a digest-pinned copy);
# 3. applies the namespace, service account, config and the Secret
#    litellm-secrets, whose values it reads from Secrets Manager (never
#    printed, never in a process argument);
# 4. runs the migration Job and stops unless it completes;
# 5. applies the Deployment and Service and waits for the rollout.
#
# Inputs: terraform/terraform.tfvars (copy terraform.tfvars.example) and the
# gateway's foundation outputs (deploy/.generated/, written by deploy/deploy.sh).
# kubectl's current context must be the cluster (aws eks update-kubeconfig).
# Prerequisites: Terraform >= 1.11, the AWS CLI, kubectl, jq, python3.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPROVE=()
for arg in "$@"; do
  case "$arg" in
    --auto-approve) APPROVE=(-auto-approve) ;;
    *) echo "Usage: $0 [--auto-approve]" >&2; exit 2 ;;
  esac
done

# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
check_kube_context
write_foundation_tfvars

terraform -chdir="$TF_DIR" apply -input=false -var-file="$TFVARS" -var-file="$FOUNDATION_TFVARS" ${APPROVE[@]+"${APPROVE[@]}"}
terraform -chdir="$TF_DIR" output -json >"${WORK_DIR}/tf-outputs.json"
NAMESPACE="$(jq -r '.namespace.value' "${WORK_DIR}/tf-outputs.json")"

MANIFESTS="${WORK_DIR}/manifests"
IMAGE_ARGS=()
[ -z "${IMAGE:-}" ] || IMAGE_ARGS=(--image "$IMAGE")
"${RENDER[@]}" manifests --tf-outputs "${WORK_DIR}/tf-outputs.json" \
  --foundation-outputs "$FOUNDATION_OUTPUTS" --out-dir "$MANIFESTS" ${IMAGE_ARGS[@]+"${IMAGE_ARGS[@]}"}

# Server-side apply everywhere: no last-applied-configuration annotation, so
# the Secret's values are stored once, in its data.
apply() { kube apply --server-side --field-manager=llmgw-eks-example "$@"; }

apply -f "${MANIFESTS}/namespace.yaml"
apply -f "${MANIFESTS}/configmap.json"

# The Secret, built in memory: each value goes from the AWS CLI's output into
# a shell variable, is base64-encoded through a pipe and reaches kubectl on
# stdin. printf is a shell builtin, so no value appears in a process list.
apply_secret() {
  local pairs env_name arn value doc
  pairs="$("${RENDER[@]}" secret-arns --foundation-outputs "$FOUNDATION_OUTPUTS")"
  doc="apiVersion: v1
kind: Secret
metadata:
  name: litellm-secrets
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: litellm
type: Opaque
data:
"
  while read -r env_name arn; do
    value="$(aws secretsmanager get-secret-value --secret-id "$arn" --query SecretString --output text)" ||
      die "could not read ${env_name} from Secrets Manager."
    [ -n "$value" ] || die "${env_name} is empty in Secrets Manager."
    doc+="  ${env_name}: $(printf '%s' "$value" | base64 | tr -d '\n')
"
  done <<<"$pairs"
  value=""
  printf '%s' "$doc" | apply -f -
  doc=""
}
secret_version() { kube get secret litellm-secrets --ignore-not-found -o jsonpath='{.metadata.resourceVersion}'; }
SECRET_BEFORE="$(secret_version)"
apply_secret
SECRET_CHANGED=false
[ -z "$SECRET_BEFORE" ] || [ "$SECRET_BEFORE" = "$(secret_version)" ] || SECRET_CHANGED=true

# Migration gate: LiteLLM reports healthy on an unmigrated database, so the
# Deployment only rolls after the Job has completed. A Job's pod template is
# immutable: the previous run is deleted first.
kube delete job litellm-migrate --ignore-not-found --cascade=foreground --wait=true >/dev/null
apply -f "${MANIFESTS}/migrate-job.yaml"
echo "Waiting for the migration Job (at most 20 minutes)"
deadline=$((SECONDS + 1500))
while :; do
  state=" $(kube get job litellm-migrate -o jsonpath='{range .status.conditions[?(@.status=="True")]}{.type}{" "}{end}') "
  case "$state" in
    *" Complete "*) echo "Migration succeeded"; break ;;
    *" Failed "*)
      echo "Migration failed; the Deployment was not changed. Inspect: kubectl -n ${NAMESPACE} logs job/litellm-migrate" >&2
      exit 1 ;;
  esac
  [ "$SECONDS" -lt "$deadline" ] || die "the migration Job did not finish; the Deployment was not changed. Inspect: kubectl -n ${NAMESPACE} describe job litellm-migrate"
  sleep 10
done

generation() { kube get deployment litellm --ignore-not-found -o jsonpath='{.metadata.generation}'; }
GENERATION_BEFORE="$(generation)"
apply -f "${MANIFESTS}/deployment.yaml" -f "${MANIFESTS}/service.yaml"
# Pods read the Secret at start: restart them when only the Secret changed
# (for example after a secret rotation).
if [ "$SECRET_CHANGED" = true ] && [ "$GENERATION_BEFORE" = "$(generation)" ]; then
  echo "Secret changed: restarting the pods"
  kube rollout restart deployment/litellm
fi
kube rollout status deployment/litellm --timeout=15m ||
  die "the rollout did not complete; the previous pods keep serving (maxUnavailable 0). Inspect: kubectl -n ${NAMESPACE} describe deployment litellm; undo: kubectl -n ${NAMESPACE} rollout undo deployment/litellm"

cat <<EOF

Done. The gateway runs as Service litellm (ClusterIP, port 4000) in namespace ${NAMESPACE}. To test it:
  kubectl -n ${NAMESPACE} port-forward service/litellm 4000:4000
  deploy/smoke-test.sh --key-secret-arn "\$(jq -r .master_key_secret_arn ${FOUNDATION_OUTPUTS})" http://127.0.0.1:4000
EOF
