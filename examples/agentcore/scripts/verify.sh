#!/bin/bash
# Show that the agent's calls went through the gateway: the agent key's spend
# and limits, and its most recent request logs in LiteLLM (model, tokens,
# cost, status). Prompts and responses are not shown.
#
#   AWS_REGION=<gateway region> scripts/verify.sh
#
# Run it where the gateway is reachable. Prerequisites as for agent-key.sh.
# Request logs appear after LiteLLM's batch write interval (about a minute).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$(dirname "$SCRIPT_DIR")/terraform"

echo "== Agent key (LiteLLM)"
"${SCRIPT_DIR}/agent-key.sh" status

umask 077
WORK="$(mktemp -d "${TMPDIR:-/tmp}/agent-verify.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
S="$(terraform -chdir="$TF_DIR" output -json gateway_key_settings)"
GATEWAY_URL="$(jq -r .gateway_url <<<"$S")"
ALIAS="$(jq -r .key_request.key_alias <<<"$S")"
MK="$(aws secretsmanager get-secret-value --secret-id "$(jq -r .master_key_secret_arn <<<"$S")" --query SecretString --output text)"
printf 'Authorization: Bearer %s\n' "$MK" >"${WORK}/h"
unset MK

TOKEN="$(curl -sS -m 30 -H "@${WORK}/h" "${GATEWAY_URL}/key/list?key_alias=${ALIAS}&return_full_object=true" |
  jq -r --arg a "$ALIAS" '[.keys[] | select(.key_alias == $a)] | first | .token // empty')"
[ -n "$TOKEN" ] || { echo "No LiteLLM key ${ALIAS}." >&2; exit 1; }

echo "== Recent requests made with the agent key (LiteLLM spend logs)"
curl -sS -m 30 -H "@${WORK}/h" "${GATEWAY_URL}/spend/logs?api_key=${TOKEN}" |
  jq '[ .[] | {startTime, key_alias: .metadata.user_api_key_alias, model_group, model, status,
               prompt_tokens, completion_tokens, spend, request_id} ]
      | sort_by(.startTime) | .[-10:]'
