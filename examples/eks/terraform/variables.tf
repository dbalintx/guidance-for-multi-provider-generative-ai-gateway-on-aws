# Inputs of the example. Gateway values are plain variables: scripts/deploy.sh
# passes vpc_cidr and kms_key_arn from the foundation outputs; this root module
# never reads or changes the gateway's own state or resources.

variable "name" {
  description = "Name prefix of the example's AWS resources (IAM role, request-log bucket)."
  type        = string
  default     = "llmgw-eks"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,19}$", var.name))
    error_message = "name must be 3-20 characters: a lower-case letter, then lower-case letters, digits or hyphens (it prefixes an S3 bucket name)."
  }
}

variable "deployment_name" {
  description = "deployment_name of the gateway (deploy/terraform.tfvars). scripts/deploy.sh reads the foundation outputs from deploy/.generated/<deployment_name>-foundation-outputs.tfvars.json."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,19}$", var.deployment_name))
    error_message = "deployment_name must match the gateway's deployment_name."
  }
}

variable "cluster_name" {
  description = "Name of the existing EKS cluster, in the gateway's region and VPC. It needs the EKS Pod Identity Agent (built into EKS Auto Mode; an add-on otherwise)."
  type        = string

  validation {
    condition     = can(regex("^[0-9A-Za-z][A-Za-z0-9_-]{0,99}$", var.cluster_name))
    error_message = "cluster_name must be an EKS cluster name."
  }
}

variable "namespace" {
  description = "Kubernetes namespace of the gateway pods (created by scripts/deploy.sh)."
  type        = string
  default     = "litellm"

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", var.namespace))
    error_message = "namespace must be a Kubernetes DNS label."
  }
}

variable "service_account" {
  description = "Kubernetes service account of the gateway pods; the Pod Identity association binds the IAM role to it."
  type        = string
  default     = "litellm"

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", var.service_account))
    error_message = "service_account must be a Kubernetes DNS label."
  }
}

variable "vpc_cidr" {
  description = "Foundation output vpc_cidr: the proxy range LiteLLM trusts for X-Forwarded-For (same as the ECS deployment)."
  type        = string

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr))
    error_message = "vpc_cidr must be an IPv4 CIDR."
  }
}

variable "kms_key_arn" {
  description = "Foundation output kms_key_arn: the customer KMS key, or null for AWS-managed keys. Encrypts the request-log bucket."
  type        = string
  default     = null
}

variable "request_log_retention_days" {
  description = "Days the request logs (metadata only) are kept in the example's bucket."
  type        = number
  default     = 30

  validation {
    condition     = var.request_log_retention_days >= 1 && floor(var.request_log_retention_days) == var.request_log_retention_days
    error_message = "request_log_retention_days must be a whole number of at least 1."
  }
}

variable "tags" {
  description = "Extra tags applied to every resource."
  type        = map(string)
  default     = {}
}
