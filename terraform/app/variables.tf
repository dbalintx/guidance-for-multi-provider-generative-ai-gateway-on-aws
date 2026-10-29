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

variable "public_subnet_ids" {
  description = "Foundation output: public subnets for the internet-facing ALB. Required (2+ subnets, different AZs) in public mode; ignored in private mode."
  type        = list(string)
  default     = []

  validation {
    condition     = !var.public_mode || length(var.public_subnet_ids) >= 2
    error_message = "public_mode needs at least two public_subnet_ids in different Availability Zones for the internet-facing ALB."
  }
}

variable "ui_password_secret_arn" {
  description = "Foundation output: Secrets Manager ARN of the LiteLLM admin UI password, kept separate from the master key (2.12)."
  type        = string
  default     = null
}

variable "rds_instance_identifier" {
  description = "Foundation output: RDS instance identifier (alarm and dashboard dimension)."
  type        = string
  default     = null
}

variable "redis_replication_group_id" {
  description = "Foundation output: ElastiCache replication group ID (alarm and dashboard dimension)."
  type        = string
  default     = null
}

variable "redis_num_cache_clusters" {
  description = "Foundation output: number of Redis nodes, for the per-node alarms."
  type        = number
  default     = 2
}

variable "vpn_security_group_id" {
  description = "Foundation output: the demo Client VPN's security group, admitted to the ALB like client_security_group_ids. Null (the default) when the foundation has no VPN."
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

# --- App-only inputs (never wired from foundation) ---

variable "client_cidrs" {
  description = "Private mode: CIDR ranges allowed to reach the ALB (VPN, Direct Connect, Transit Gateway). Empty means the VPC CIDR only — never all of RFC 1918."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for c in var.client_cidrs : can(cidrhost(c, 0))])
    error_message = "Every client_cidrs entry must be a valid IPv4 CIDR, for example 10.20.0.0/16."
  }
}

variable "client_security_group_ids" {
  description = "Extra security groups allowed to reach the ALB. The foundation's demo Client VPN is admitted automatically via vpn_security_group_id."
  type        = list(string)
  default     = []
}

variable "deletion_protection" {
  description = "Protect the ALB from deletion and keep the log buckets on destroy. Set false and apply before undeploying."
  type        = bool
  default     = true
}

variable "architecture" {
  description = "CPU architecture of the Fargate tasks: x86 or arm. The official LiteLLM image is multi-arch; Graviton is cheaper."
  type        = string
  default     = "arm"

  validation {
    condition     = contains(["x86", "arm"], var.architecture)
    error_message = "architecture must be x86 or arm."
  }
}

variable "vcpus" {
  description = "vCPUs per gateway task (memory is 2 GiB per vCPU)."
  type        = number
  default     = 2
}

variable "desired_capacity" {
  description = "Task count at creation. After that, auto scaling owns the count: redeploys never reset it."
  type        = number
  default     = 2
}

variable "min_capacity" {
  description = "Auto scaling minimum task count."
  type        = number
  default     = 2
}

variable "max_capacity" {
  description = "Auto scaling maximum task count."
  type        = number
  default     = 4
}

variable "cpu_target_utilization_percent" {
  description = "Target-tracking CPU utilization for service auto scaling."
  type        = number
  default     = 75
}

variable "memory_target_utilization_percent" {
  description = "Target-tracking memory utilization for service auto scaling."
  type        = number
  default     = 70
}

variable "log_level" {
  description = "LITELLM_LOG level. DEBUG writes prompts and provider payloads to the logs (verified on 1.82.3 and 1.106.0): temporary troubleshooting only — the plan warns while it is on."
  type        = string
  default     = "INFO"

  validation {
    condition     = contains(["ERROR", "WARNING", "INFO", "DEBUG"], var.log_level)
    error_message = "log_level must be one of ERROR, WARNING, INFO, DEBUG."
  }
}

variable "log_retention_days" {
  description = "Retention of the LiteLLM CloudWatch logs and of the S3 access/request logs."
  type        = number
  default     = 90
}

variable "waf_rate_limit_per_5_min" {
  description = "Public mode WAF rate-based rule: requests per source IP per 5 minutes before blocking. LiteLLM's own per-key and per-team limits still apply."
  type        = number
  default     = 2000
}

variable "include_default_models" {
  description = "Load the repository's legacy default model lists (config/default-config-base.yaml + the region file). Off by default: new deployments should add models in the LiteLLM UI (2.17)."
  type        = bool
  default     = false
}

variable "config_override_file" {
  description = "Optional YAML file merged over the rendered LiteLLM config: model_list entries are appended; general_settings, litellm_settings and router_settings keys override the base."
  type        = string
  default     = null
}

variable "bedrock_model_allowlist" {
  description = "Optional Bedrock model IDs the task role may invoke. Empty = any model and inference profile in the allowed regions (model access is still governed in Bedrock and in LiteLLM teams)."
  type        = list(string)
  default     = []
}

variable "bedrock_region_allowlist" {
  description = "Optional regions the task role may invoke Bedrock in. Empty = any region, so cross-region inference profiles and new regions keep working."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for r in var.bedrock_region_allowlist : can(regex("^[a-z]{2}(-[a-z]+)+-\\d$", r))])
    error_message = "Every bedrock_region_allowlist entry must be a region name such as eu-west-1."
  }
}

variable "cross_account_role_arns" {
  description = "Roles in other accounts LiteLLM may assume for Bedrock models or guardrails, listed explicitly. A role/* wildcard is rejected."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for a in var.cross_account_role_arns : can(regex("^arn:aws[a-z-]*:iam::\\d{12}:role/", a)) && !strcontains(a, "*")])
    error_message = "cross_account_role_arns must be explicit role ARNs (arn:aws:iam::<account>:role/<name>); wildcards are rejected."
  }
}

variable "provider_secret_arns" {
  description = "Environment variable name => Secrets Manager ARN (optionally with the :json-key:: suffix) for non-Bedrock provider API keys. Values never pass through variables or state."
  type        = map(string)
  default     = {}
}

variable "extra_environment" {
  description = "Additional non-secret environment variables for LiteLLM (for example SSO client IDs, PROXY_BASE_URL, HTTPS_PROXY)."
  type        = map(string)
  default     = {}
}

variable "run_migrations_on_apply" {
  description = "Run the LiteLLM schema migration as a one-off ECS task, and gate the service rollout on its exit code (needs the AWS CLI where Terraform runs). Disable only when running the migration out of band."
  type        = bool
  default     = true
}

variable "alarm_email" {
  description = "Optional email address subscribed to the alarm topic (confirm the subscription from the email AWS sends)."
  type        = string
  default     = null
}
