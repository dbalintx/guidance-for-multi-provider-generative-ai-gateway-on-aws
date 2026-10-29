# App: gateway + monitoring. Destroyable and re-deployable against a living
# foundation at any time. Consumes the foundation ONLY through the plain input
# variables below (no terraform_remote_state) — deploy/deploy.sh wires
# `terraform output -json` from terraform/foundation into them.

variable "deployment_name" {
  description = "Name prefix for every resource. Must match the foundation's deployment_name."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,19}$", var.deployment_name))
    error_message = "deployment_name must start with a lowercase letter and contain only lowercase letters, digits and hyphens (max 20 characters), so it can prefix S3 bucket, secret and database identifier names."
  }
}

variable "tags" {
  description = "Customer tags merged into the default tags applied to every resource."
  type        = map(string)
  default     = {}
}

# --- Wired from foundation outputs by deploy/deploy.sh (names match 1:1) ---

variable "vpc_id" {
  description = "Foundation output: the VPC everything runs in."
  type        = string
  default     = null
}

variable "private_subnet_ids" {
  description = "Foundation output: private subnets for the gateway tasks."
  type        = list(string)
  default     = []
}

variable "vpc_cidr" {
  description = "Foundation output: the VPC's IPv4 CIDR."
  type        = string
  default     = null
}

variable "db_endpoint" {
  description = "Foundation output: RDS PostgreSQL endpoint (host:port)."
  type        = string
  default     = null
}

variable "database_url_secret_arn" {
  description = "Foundation output: Secrets Manager ARN of the DATABASE_URL."
  type        = string
  default     = null
}

variable "redis_endpoint" {
  description = "Foundation output: ElastiCache Redis primary endpoint."
  type        = string
  default     = null
}

variable "redis_port" {
  description = "Foundation output: ElastiCache Redis port."
  type        = number
  default     = null
}

variable "redis_auth_secret_arn" {
  description = "Foundation output: Secrets Manager ARN of the Redis auth token."
  type        = string
  default     = null
}

variable "config_bucket_name" {
  description = "Foundation output: versioned S3 bucket for the rendered LiteLLM config."
  type        = string
  default     = null
}

variable "master_key_secret_arn" {
  description = "Foundation output: Secrets Manager ARN of the LiteLLM master key."
  type        = string
  default     = null
}

variable "salt_key_secret_arn" {
  description = "Foundation output: Secrets Manager ARN of the LiteLLM salt key."
  type        = string
  default     = null
}

variable "kms_key_arn" {
  description = "Foundation output: customer KMS key, or null for AWS-managed keys."
  type        = string
  default     = null
}

variable "data_ingress_security_group_id" {
  description = "Foundation output: security group granting access to RDS and Redis."
  type        = string
  default     = null
}

# --- Modes (Milestone 1 contract) ---

variable "public_mode" {
  description = "false (default): internal ALB, reachable from the VPC / listed client ranges only. true: internet-facing ALB with WAF attached."
  type        = bool
  default     = false
}

variable "certificate_arn" {
  description = "The customer's ACM certificate for the ALB HTTPS listener. Required unless allow_insecure_http."
  type        = string
  default     = null

  validation {
    condition     = var.allow_insecure_http || var.certificate_arn != null
    error_message = "A certificate_arn is required. Only a private proof of concept may set allow_insecure_http = true instead."
  }
}

variable "allow_insecure_http" {
  description = "Private trials only: serve plain HTTP without a certificate. Rejected in public mode."
  type        = bool
  default     = false

  validation {
    condition     = !(var.allow_insecure_http && var.public_mode)
    error_message = "allow_insecure_http is for private proofs of concept only and cannot be combined with public_mode."
  }
}

variable "hosted_zone_id" {
  description = "Optional Route 53 hosted zone; with record_name, creates an alias to the ALB. Set both or neither."
  type        = string
  default     = null
}

variable "record_name" {
  description = "Optional DNS name (for example llm.example.com) created in hosted_zone_id. Set both or neither."
  type        = string
  default     = null

  validation {
    condition     = (var.hosted_zone_id == null) == (var.record_name == null)
    error_message = "hosted_zone_id and record_name must be set together: a name without a zone, or a zone without a name, is rejected."
  }
}

variable "identity_provider" {
  description = "Optional OIDC identity provider. When set, the ALB requires sign-in in front of the LiteLLM UI paths — unconditionally, in private and public mode alike (decisions.md). The client secret is given as a Secrets Manager ARN; its value never passes through variables."
  type = object({
    issuer                 = string
    authorization_endpoint = string
    token_endpoint         = string
    user_info_endpoint     = string
    client_id              = string
    client_secret_arn      = string
  })
  default = null

  validation {
    condition     = !(var.identity_provider != null && var.allow_insecure_http)
    error_message = "The ALB OIDC sign-in action requires HTTPS: an identity provider cannot be combined with allow_insecure_http."
  }
}

variable "litellm_license_secret_arn" {
  description = "Optional Secrets Manager ARN of the LiteLLM Enterprise licence. Null runs reduced mode (trials and exploration only)."
  type        = string
  default     = null
}
