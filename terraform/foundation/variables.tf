# Foundation: long-lived network + data. Nothing in this root module may
# reference ECS, the ALB, or any other app concept (Milestone 1 contract).

variable "deployment_name" {
  description = "Name prefix for every resource. Two deployments in one account must use different names."
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

variable "vpc_id" {
  description = "Bring-your-own VPC ID. Leave null to create a VPC. BYO subnets are validated before anything is created (vpc-validation module, separate Milestone 1 branch)."
  type        = string
  default     = null
}

variable "private_subnet_ids" {
  description = "Bring-your-own VPC only: at least two private subnets in different Availability Zones."
  type        = list(string)
  default     = []
}

variable "extra_data_ingress_security_group_ids" {
  description = "Extra security groups admitted to RDS and Redis, for any non-ECS client of the data stores (for example the Milestone 2 EKS example)."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for id in var.extra_data_ingress_security_group_ids : can(regex("^sg-[0-9a-f]{8,17}$", id))])
    error_message = "Every entry must be a security group ID (sg-...)."
  }
}

variable "extra_data_ingress_cidrs" {
  description = "Extra CIDR ranges admitted to RDS and Redis, for any non-ECS client of the data stores."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for cidr in var.extra_data_ingress_cidrs : can(cidrnetmask(cidr))])
    error_message = "Every entry must be a valid IPv4 CIDR (for example 10.1.0.0/16)."
  }
}

variable "kms_key_arn" {
  description = "Optional customer KMS key for the database, Redis, secrets, logs and S3. Null uses AWS-managed keys."
  type        = string
  default     = null
}

variable "deletion_protection" {
  description = "Protects the database from deletion and keeps buckets on destroy. Set to false and apply before undeploying."
  type        = bool
  default     = true
}
