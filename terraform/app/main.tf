# Child modules land on dedicated Milestone 1 branches:
#   ALB + listeners + optional WAF + optional OIDC sign-in; ECS cluster/service/
#   task + one-off migration task; rendered LiteLLM config (templatefile -> S3,
#   content hash in the task definition); observability (alarms + dashboard).
# No custom code in the request path: no sidecars, no wrappers, no LiteLLM patches.
