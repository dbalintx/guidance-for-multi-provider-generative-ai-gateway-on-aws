# The EKS-compatibility surface (Milestone 1 contract / decisions.md): everything
# a non-ECS consumer of the foundation needs. `app` consumes these through plain
# input variables only — deploy/deploy.sh wires `terraform output -json` from
# this root module into terraform/app. Keep names in sync with app's variables.
#
# Null values are placeholders until the owning Milestone 1 branch wires the
# real resource; they are listed here so the output surface (and the deploy
# wiring) is fixed from the start.

output "vpc_id" {
  description = "The VPC everything runs in (created or brought)."
  value       = var.vpc_id # TODO(m1 network branch): created VPC when var.vpc_id is null
}

output "private_subnet_ids" {
  description = "Private subnets for the gateway tasks and data stores."
  value       = var.private_subnet_ids # TODO(m1 network branch): created subnets when creating the VPC
}

output "vpc_cidr" {
  description = "The VPC's IPv4 CIDR."
  value       = null # TODO(m1 network branch)
}

output "db_endpoint" {
  description = "RDS PostgreSQL endpoint (host:port)."
  value       = null # TODO(m1 data branch)
}

output "database_url_secret_arn" {
  description = "Secrets Manager ARN of the full DATABASE_URL (the value never appears in state outputs or variables)."
  value       = null # TODO(m1 data branch)
}

output "redis_endpoint" {
  description = "ElastiCache Redis primary endpoint."
  value       = null # TODO(m1 data branch)
}

output "redis_port" {
  description = "ElastiCache Redis port."
  value       = null # TODO(m1 data branch)
}

output "redis_auth_secret_arn" {
  description = "Secrets Manager ARN of the Redis auth token."
  value       = null # TODO(m1 data branch)
}

output "config_bucket_name" {
  description = "Versioned S3 bucket holding the rendered LiteLLM config."
  value       = null # TODO(m1 data branch)
}

output "master_key_secret_arn" {
  description = "Secrets Manager ARN of the generated LiteLLM master key."
  value       = null # TODO(m1 secrets branch)
}

output "salt_key_secret_arn" {
  description = "Secrets Manager ARN of the generated LiteLLM salt key (never rotate it)."
  value       = null # TODO(m1 secrets branch)
}

output "kms_key_arn" {
  description = "The customer KMS key, or null when AWS-managed keys are used."
  value       = var.kms_key_arn
}

output "data_ingress_security_group_id" {
  description = "The security group whose membership grants access to RDS and Redis; app attaches it to the gateway tasks."
  value       = null # TODO(m1 data branch)
}
