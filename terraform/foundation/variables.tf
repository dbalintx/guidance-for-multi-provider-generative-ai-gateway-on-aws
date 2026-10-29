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
  description = "Bring-your-own VPC ID. Leave null to create a VPC. BYO subnets are listed explicitly and validated at plan time, before anything is created (vpc-validation.tf)."
  type        = string
  default     = null

  validation {
    condition     = var.vpc_id == null ? length(var.private_subnet_ids) == 0 : length(var.private_subnet_ids) >= 2
    error_message = "With vpc_id set, list at least two private subnets in private_subnet_ids; when creating a VPC (vpc_id = null), leave private_subnet_ids empty."
  }
}

variable "private_subnet_ids" {
  description = "Bring-your-own VPC only: at least two private subnets in different Availability Zones."
  type        = list(string)
  default     = []
}

variable "public_subnet_ids" {
  description = "Bring-your-own VPC, public mode only: public subnets in at least two Availability Zones for the internet-facing entry point."
  type        = list(string)
  default     = []

  validation {
    condition     = var.vpc_id != null || length(var.public_subnet_ids) == 0
    error_message = "public_subnet_ids is only used with a bring-your-own vpc_id; when creating a VPC, public subnets are created as needed."
  }
}

variable "public_mode" {
  description = "Shared with the app root module (one terraform.tfvars feeds both): the entry point is internet-facing, so the network needs public subnets in two Availability Zones. Foundation only validates/creates the subnets; it knows nothing about what runs in them."
  type        = bool
  default     = false

  validation {
    condition     = !(var.public_mode && var.disable_outbound_network_access)
    error_message = "public_mode needs an internet gateway; it cannot be combined with disable_outbound_network_access."
  }
}

variable "vpc_cidr" {
  description = "IPv4 CIDR for the created VPC. Ignored for a bring-your-own VPC."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrsubnet(var.vpc_cidr, 3, 3)) && tonumber(split("/", var.vpc_cidr)[1]) <= 24
    error_message = "vpc_cidr must be an IPv4 CIDR no smaller than /24, so four subnets can be carved out of it."
  }
}

variable "disable_outbound_network_access" {
  description = "No-internet mode for the created VPC: no internet gateway, no NAT, AWS services through VPC endpoints only. The online licence check, an IdP and non-Bedrock providers are unreachable without an egress proxy."
  type        = bool
  default     = false
}

variable "create_vpc_endpoints_in_existing_vpc" {
  description = "Bring-your-own VPC only: also create the interface/gateway VPC endpoints in it. Leave false when the VPC already has them."
  type        = bool
  default     = false
}

variable "egress_proxy_configured" {
  description = "An HTTPS proxy handles outbound traffic from the private subnets. Only suppresses the no-egress warning; the proxy itself is configured on the gateway."
  type        = bool
  default     = false
}

variable "max_gateway_instances" {
  description = "Largest number of gateway replicas expected to run concurrently, used only to check free IP addresses in bring-your-own subnets (rolling deploys run up to twice this)."
  type        = number
  default     = 4

  validation {
    condition     = var.max_gateway_instances >= 1
    error_message = "max_gateway_instances must be at least 1."
  }
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

variable "secret_recovery_window_days" {
  description = "Recovery window for deleted secrets. 0 deletes immediately (test deployments only)."
  type        = number
  default     = 7

  validation {
    condition     = var.secret_recovery_window_days == 0 || (var.secret_recovery_window_days >= 7 && var.secret_recovery_window_days <= 30)
    error_message = "secret_recovery_window_days must be 0 (immediate, tests only) or between 7 and 30."
  }
}

variable "log_retention_days" {
  description = "CloudWatch retention for the foundation's log groups (VPC flow logs)."
  type        = number
  default     = 90
}

variable "db_engine_version" {
  description = "PostgreSQL engine version. A major version (for example \"17\") lets RDS pick the latest minor release."
  type        = string
  default     = "17"
}

variable "rds_instance_class" {
  description = "Instance class for the RDS database."
  type        = string
  default     = "db.t3.small"
}

variable "rds_allocated_storage" {
  description = "Allocated storage in GB for the RDS database."
  type        = number
  default     = 20
}

variable "db_backup_retention_days" {
  description = "RDS automated backup retention in days."
  type        = number
  default     = 30

  validation {
    condition     = var.db_backup_retention_days >= 1 && var.db_backup_retention_days <= 35
    error_message = "db_backup_retention_days must be between 1 and 35."
  }
}

variable "redis_node_type" {
  description = "Node type for the Redis cache clusters."
  type        = string
  default     = "cache.t3.micro"
}

variable "redis_num_cache_clusters" {
  description = "Number of Redis cache clusters (primary + replicas). Multi-AZ needs at least 2."
  type        = number
  default     = 2

  validation {
    condition     = var.redis_num_cache_clusters >= 2
    error_message = "redis_num_cache_clusters must be at least 2: Multi-AZ with automatic failover needs a replica."
  }
}

# --- Optional demo Client VPN (terraform/modules/vpn) ---

variable "create_vpn" {
  description = "Create the demo/test Client VPN into the VPC (mutual TLS, split tunnel, VPC range only). Not a production access path. Run deploy/setup-vpn.sh certs first for the two certificate ARNs."
  type        = bool
  default     = false
}

variable "vpn_server_certificate_arn" {
  description = "ACM ARN of the Client VPN server certificate (printed by deploy/setup-vpn.sh certs). Required when create_vpn."
  type        = string
  default     = null

  validation {
    condition     = !var.create_vpn || var.vpn_server_certificate_arn != null
    error_message = "create_vpn needs vpn_server_certificate_arn (run deploy/setup-vpn.sh certs to create and import it)."
  }
}

variable "vpn_client_root_certificate_arn" {
  description = "ACM ARN whose chain validates the VPN client certificate (printed by deploy/setup-vpn.sh certs). Required when create_vpn."
  type        = string
  default     = null

  validation {
    condition     = !var.create_vpn || var.vpn_client_root_certificate_arn != null
    error_message = "create_vpn needs vpn_client_root_certificate_arn (run deploy/setup-vpn.sh certs to create and import it)."
  }
}

variable "vpn_client_cidr" {
  description = "Address range VPN clients get (a /12 to /22 that must not overlap the VPC CIDR)."
  type        = string
  default     = "10.250.0.0/22"
}

variable "vpn_egress_ports" {
  description = "TCP ports VPN clients may reach in the VPC. The default reaches the HTTPS listener; an allow_insecure_http trial needs [443, 80]."
  type        = list(number)
  default     = [443]
}
