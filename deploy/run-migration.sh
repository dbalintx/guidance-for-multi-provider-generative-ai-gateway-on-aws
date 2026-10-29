#!/bin/bash
# Run LiteLLM's database migration once, as a one-off ECS task, and fail if it
# fails. Called by Terraform (terraform_data.migrate in terraform/app/ecs.tf)
# during `terraform apply`, BEFORE the service rolls to a new task definition:
# LiteLLM's health endpoints report healthy on an unmigrated database (verified
# on 1.82.3 and 1.106.0), so nothing downstream would catch a missed migration.
#
# Inputs (environment): CLUSTER, TASK_DEFINITION, SUBNETS (comma-separated),
# SECURITY_GROUPS (comma-separated), AWS_REGION. No secrets are read or printed.
set -euo pipefail

: "${CLUSTER:?}" "${TASK_DEFINITION:?}" "${SUBNETS:?}" "${SECURITY_GROUPS:?}" "${AWS_REGION:?}"

echo "Starting migration task ${TASK_DEFINITION} on ${CLUSTER}"
TASK_ARN=$(aws ecs run-task \
  --region "$AWS_REGION" \
  --cluster "$CLUSTER" \
  --task-definition "$TASK_DEFINITION" \
  --launch-type FARGATE \
  --count 1 \
  --network-configuration "awsvpcConfiguration={subnets=[${SUBNETS}],securityGroups=[${SECURITY_GROUPS}],assignPublicIp=DISABLED}" \
  --query 'tasks[0].taskArn' --output text)

if [ -z "$TASK_ARN" ] || [ "$TASK_ARN" = "None" ]; then
  echo "Could not start the migration task" >&2
  exit 1
fi

echo "Waiting for ${TASK_ARN}"
aws ecs wait tasks-stopped --region "$AWS_REGION" --cluster "$CLUSTER" --tasks "$TASK_ARN"

EXIT_CODE=$(aws ecs describe-tasks --region "$AWS_REGION" --cluster "$CLUSTER" --tasks "$TASK_ARN" \
  --query 'tasks[0].containers[0].exitCode' --output text)
REASON=$(aws ecs describe-tasks --region "$AWS_REGION" --cluster "$CLUSTER" --tasks "$TASK_ARN" \
  --query 'tasks[0].stoppedReason' --output text)

if [ "$EXIT_CODE" != "0" ]; then
  echo "Migration failed (exit code ${EXIT_CODE}, ${REASON}). The service was not rolled." >&2
  exit 1
fi
echo "Migration succeeded"
