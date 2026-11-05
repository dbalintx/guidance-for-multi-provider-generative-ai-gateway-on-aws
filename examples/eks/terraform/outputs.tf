# Read by scripts/render.py (terraform output -json). No secrets.

output "region" {
  description = "Region of the cluster and the gateway (AWS_REGION in the pods)."
  value       = local.region
}

output "namespace" {
  description = "Kubernetes namespace of the gateway pods."
  value       = var.namespace
}

output "service_account" {
  description = "Kubernetes service account bound to pod_role_arn by the Pod Identity association."
  value       = aws_eks_pod_identity_association.litellm.service_account
}

output "pod_role_arn" {
  description = "IAM role the gateway pods receive through EKS Pod Identity."
  value       = aws_iam_role.pod.arn
}

output "request_log_bucket_name" {
  description = "S3 bucket of the LiteLLM request logs (metadata only)."
  value       = aws_s3_bucket.request_logs.bucket
}

output "litellm_config_yaml" {
  description = "The rendered LiteLLM config.yaml (no secrets), delivered as a ConfigMap."
  value       = local.litellm_config_yaml
}

output "config_sha" {
  description = "SHA-256 of litellm_config_yaml: names the ConfigMap and sets LITELLM_CONFIG_SHA, so a config change rolls the pods."
  value       = local.config_sha
}
