# Data-store protection, logging and key wiring, with mocked
# providers. Default variables plan the created-VPC path.

mock_provider "aws" {
  mock_data "aws_region" {
    defaults = { region = "eu-west-1" }
  }
  mock_data "aws_availability_zones" {
    defaults = { names = ["eu-west-1a", "eu-west-1b"] }
  }
  mock_data "aws_vpc_endpoint" {
    defaults = { id = "vpce-1" }
  }
}

mock_provider "random" {}

variables {
  deployment_name = "llmgw"
}

# Generated values are normally unknown until apply; make them known at plan
# time so the wiring assertions can read them.
override_resource {
  target          = random_password.redis_auth
  override_during = plan
  values          = { result = "mocked-redis-auth-token-32-chars" }
}

override_resource {
  target          = aws_s3_bucket.config
  override_during = plan
  values          = { arn = "arn:aws:s3:::llmgw-config-mock", bucket = "llmgw-config-mock" }
}

override_resource {
  target          = aws_secretsmanager_secret.master_key
  override_during = plan
  values          = { arn = "arn:aws:secretsmanager:eu-west-1:123456789012:secret:llmgw-master-key-abc" }
}

override_resource {
  target          = aws_secretsmanager_secret.salt_key
  override_during = plan
  values          = { arn = "arn:aws:secretsmanager:eu-west-1:123456789012:secret:llmgw-salt-key-abc" }
}

override_resource {
  target          = aws_secretsmanager_secret.redis_auth
  override_during = plan
  values          = { arn = "arn:aws:secretsmanager:eu-west-1:123456789012:secret:llmgw-redis-auth-abc" }
}

override_resource {
  target          = aws_secretsmanager_secret.ui_password
  override_during = plan
  values          = { arn = "arn:aws:secretsmanager:eu-west-1:123456789012:secret:llmgw-ui-password-abc" }
}

override_resource {
  target          = aws_secretsmanager_secret.database_url
  override_during = plan
  values          = { arn = "arn:aws:secretsmanager:eu-west-1:123456789012:secret:llmgw-database-url-abc" }
}

run "rds_is_hardened_by_default" {
  command = plan

  assert {
    condition     = aws_db_instance.database.multi_az && aws_db_instance.database.storage_encrypted
    error_message = "The database must be Multi-AZ and encrypted."
  }

  assert {
    condition     = aws_db_instance.database.deletion_protection && !aws_db_instance.database.skip_final_snapshot && aws_db_instance.database.final_snapshot_identifier != null
    error_message = "Deletion protection and a final snapshot must be on by default."
  }

  assert {
    condition     = aws_db_instance.database.backup_retention_period == 30 && aws_db_instance.database.copy_tags_to_snapshot
    error_message = "Backups must be kept for 30 days by default."
  }

  assert {
    condition     = aws_db_instance.database.apply_immediately == false
    error_message = "Database changes must wait for the maintenance window."
  }

  assert {
    condition     = aws_db_instance.database.identifier == "llmgw-litellm-db" && aws_db_instance.database.engine == "postgres"
    error_message = "The database identifier must derive from deployment_name."
  }
}

run "db_logs_schema_changes_and_slow_queries_only" {
  command = plan

  assert {
    condition = anytrue([
      for p in aws_db_parameter_group.postgres.parameter : p.name == "log_statement" && p.value == "ddl"
    ])
    error_message = "log_statement must be ddl: logging every statement would send spend logs, keys and team data to CloudWatch."
  }

  assert {
    condition = anytrue([
      for p in aws_db_parameter_group.postgres.parameter : p.name == "log_min_duration_statement" && p.value == "5000"
    ])
    error_message = "Only slow queries (>= 5 s) may be logged."
  }

  assert {
    condition     = contains(aws_db_instance.database.enabled_cloudwatch_logs_exports, "postgresql")
    error_message = "The postgresql log export must be enabled."
  }
}

run "redis_is_tls_multi_az_with_auth" {
  command = plan

  assert {
    condition     = aws_elasticache_replication_group.redis.transit_encryption_enabled && aws_elasticache_replication_group.redis.transit_encryption_mode == "required"
    error_message = "Redis must require TLS in transit."
  }

  assert {
    condition     = aws_elasticache_replication_group.redis.multi_az_enabled && aws_elasticache_replication_group.redis.automatic_failover_enabled && aws_elasticache_replication_group.redis.num_cache_clusters == 2
    error_message = "Redis must be Multi-AZ with automatic failover."
  }

  # The provider types this attribute as a string.
  assert {
    condition     = tobool(aws_elasticache_replication_group.redis.at_rest_encryption_enabled)
    error_message = "Redis must be encrypted at rest."
  }

  assert {
    condition     = aws_elasticache_replication_group.redis.auth_token != null && aws_elasticache_replication_group.redis.auth_token != ""
    error_message = "Redis must require an auth token."
  }

  assert {
    condition     = aws_elasticache_replication_group.redis.auth_token == random_password.redis_auth.result && aws_secretsmanager_secret_version.redis_auth.secret_string == random_password.redis_auth.result
    error_message = "The Redis auth token and its secret must both carry the generated value."
  }
}

run "config_bucket_is_versioned_and_private" {
  command = plan

  assert {
    condition     = aws_s3_bucket_versioning.config.versioning_configuration[0].status == "Enabled"
    error_message = "The config bucket must be versioned so a bad config can be rolled back."
  }

  assert {
    condition     = aws_s3_bucket_public_access_block.config.block_public_acls && aws_s3_bucket_public_access_block.config.block_public_policy && aws_s3_bucket_public_access_block.config.ignore_public_acls && aws_s3_bucket_public_access_block.config.restrict_public_buckets
    error_message = "All four public-access blocks must be on."
  }

  assert {
    condition     = aws_s3_bucket.config.force_destroy == false
    error_message = "The config bucket must be kept on destroy while deletion protection is on."
  }

  assert {
    condition     = strcontains(aws_s3_bucket_policy.config.policy, "aws:SecureTransport")
    error_message = "The bucket policy must deny non-TLS access."
  }
}

run "secrets_have_recovery_windows_and_stay_out_of_outputs" {
  command = plan

  assert {
    condition = alltrue([
      aws_secretsmanager_secret.master_key.recovery_window_in_days == 7,
      aws_secretsmanager_secret.salt_key.recovery_window_in_days == 7,
      aws_secretsmanager_secret.redis_auth.recovery_window_in_days == 7,
      aws_secretsmanager_secret.ui_password.recovery_window_in_days == 7,
      aws_secretsmanager_secret.database_url.recovery_window_in_days == 7,
    ])
    error_message = "Every generated secret must keep a 7-day recovery window by default."
  }

  assert {
    condition     = output.master_key_secret_arn == aws_secretsmanager_secret.master_key.arn && output.salt_key_secret_arn == aws_secretsmanager_secret.salt_key.arn
    error_message = "Outputs must expose the master/salt key secret ARNs (never values)."
  }

  assert {
    condition     = output.redis_auth_secret_arn == aws_secretsmanager_secret.redis_auth.arn && output.database_url_secret_arn == aws_secretsmanager_secret.database_url.arn && output.ui_password_secret_arn == aws_secretsmanager_secret.ui_password.arn
    error_message = "Outputs must expose the Redis auth, DATABASE_URL and UI password secret ARNs (never values)."
  }
}

run "customer_kms_key_covers_db_redis_secrets_logs_s3" {
  command = plan

  variables {
    kms_key_arn = "arn:aws:kms:eu-west-1:123456789012:key/11111111-2222-3333-4444-555555555555"
  }

  assert {
    condition     = aws_db_instance.database.kms_key_id == var.kms_key_arn && aws_db_instance.database.performance_insights_kms_key_id == var.kms_key_arn
    error_message = "The customer key must encrypt the database and Performance Insights."
  }

  assert {
    condition     = aws_elasticache_replication_group.redis.kms_key_id == var.kms_key_arn
    error_message = "The customer key must encrypt Redis at rest."
  }

  assert {
    condition = alltrue([
      aws_secretsmanager_secret.master_key.kms_key_id == var.kms_key_arn,
      aws_secretsmanager_secret.salt_key.kms_key_id == var.kms_key_arn,
      aws_secretsmanager_secret.redis_auth.kms_key_id == var.kms_key_arn,
      aws_secretsmanager_secret.ui_password.kms_key_id == var.kms_key_arn,
      aws_secretsmanager_secret.database_url.kms_key_id == var.kms_key_arn,
    ])
    error_message = "The customer key must encrypt every secret."
  }

  assert {
    condition     = aws_cloudwatch_log_group.vpc_flow_logs[0].kms_key_id == var.kms_key_arn
    error_message = "The customer key must encrypt the flow log group."
  }

  assert {
    condition = anytrue([
      for r in aws_s3_bucket_server_side_encryption_configuration.config.rule :
      r.apply_server_side_encryption_by_default[0].sse_algorithm == "aws:kms" && r.apply_server_side_encryption_by_default[0].kms_master_key_id == var.kms_key_arn
    ])
    error_message = "The customer key must encrypt the config bucket."
  }

  assert {
    condition     = output.kms_key_arn == var.kms_key_arn
    error_message = "The kms_key_arn output must pass the key through."
  }
}

run "aws_managed_keys_when_no_customer_key" {
  command = plan

  # The database's kms_key_id is computed at apply (RDS picks its default
  # aws/rds key), so only Redis is assertable at plan time.
  assert {
    condition     = aws_elasticache_replication_group.redis.kms_key_id == null
    error_message = "Null kms_key_arn must fall back to AWS-managed keys."
  }

  assert {
    condition = anytrue([
      for r in aws_s3_bucket_server_side_encryption_configuration.config.rule :
      r.apply_server_side_encryption_by_default[0].sse_algorithm == "AES256"
    ])
    error_message = "Null kms_key_arn must use SSE-S3 on the bucket."
  }
}

run "protection_off_allows_teardown" {
  command = plan

  variables {
    deletion_protection = false
  }

  assert {
    condition     = !aws_db_instance.database.deletion_protection && aws_db_instance.database.skip_final_snapshot
    error_message = "deletion_protection = false must release the database."
  }

  assert {
    condition     = aws_s3_bucket.config.force_destroy
    error_message = "deletion_protection = false must let the config bucket be destroyed."
  }
}

run "created_vpc_has_flow_logs_endpoints_and_two_az_subnets" {
  command = plan

  assert {
    condition     = length(aws_vpc.new) == 1 && length(aws_subnet.private) == 2 && length(aws_subnet.public) == 2
    error_message = "The created VPC must have two private and two public subnets."
  }

  assert {
    condition     = aws_subnet.private[0].availability_zone != aws_subnet.private[1].availability_zone
    error_message = "The created private subnets must span two Availability Zones."
  }

  assert {
    condition     = length(aws_flow_log.this) == 1 && aws_cloudwatch_log_group.vpc_flow_logs[0].retention_in_days == 90
    error_message = "The created VPC must have flow logs with the 90-day default retention."
  }

  assert {
    condition     = length(aws_vpc_endpoint.s3_gateway) == 1 && length(aws_vpc_endpoint.interface) == 7
    error_message = "The created VPC must get the S3 gateway endpoint and the 7 interface endpoints."
  }

  assert {
    condition     = aws_vpc.new[0].enable_dns_support && aws_vpc.new[0].enable_dns_hostnames
    error_message = "The created VPC must have DNS support and hostnames on (private DNS on the endpoints)."
  }

  assert {
    condition     = length(aws_nat_gateway.this) == 1 && length(aws_internet_gateway.this) == 1
    error_message = "The default created VPC must have egress through a NAT gateway."
  }
}

run "no_internet_mode_has_no_igw_nat_or_public_subnets" {
  command = plan

  variables {
    disable_outbound_network_access = true
  }

  assert {
    condition     = length(aws_internet_gateway.this) == 0 && length(aws_nat_gateway.this) == 0 && length(aws_subnet.public) == 0
    error_message = "No-internet mode must create no internet gateway, NAT or public subnets."
  }

  assert {
    condition     = length(aws_vpc_endpoint.interface) == 7 && length(aws_vpc_endpoint.s3_gateway) == 1
    error_message = "No-internet mode depends on the VPC endpoints."
  }

  assert {
    condition     = length(aws_subnet.private) == 2
    error_message = "No-internet mode still needs the two private subnets."
  }
}

run "resource_names_derive_from_deployment_name" {
  command = plan

  variables {
    deployment_name = "second"
  }

  assert {
    condition = alltrue([
      aws_db_instance.database.identifier == "second-litellm-db",
      aws_elasticache_replication_group.redis.replication_group_id == "second-redis",
      aws_security_group.data_ingress.name == "second-data-client-sg",
      aws_security_group.db.name == "second-db-sg",
      aws_security_group.redis.name == "second-redis-sg",
      aws_db_subnet_group.main.name == "second-db-subnet-group",
      aws_elasticache_subnet_group.redis.name == "second-redis-subnet-group",
    ])
    error_message = "Every resource name must derive from deployment_name so two deployments in one account do not collide."
  }
}

# deploy/smoke-test.sh --key-secret-arn reads SecretString as-is, so the master
# key secret must hold the bare key, not a JSON document.
run "master_key_secret_is_a_plain_string" {
  command = plan

  override_resource {
    target          = random_password.master_key
    override_during = plan
    values          = { result = "mockedmasterkey123456" }
  }

  assert {
    condition     = aws_secretsmanager_secret_version.master_key.secret_string == "sk-mockedmasterkey123456"
    error_message = "The master key secret must be the plain sk-... key (smoke-test.sh --key-secret-arn uses SecretString verbatim)."
  }

  assert {
    condition     = !can(jsondecode(aws_secretsmanager_secret_version.master_key.secret_string))
    error_message = "The master key secret must not be JSON."
  }
}

run "monitoring_identifiers_exported" {
  command = plan

  variables {
    redis_num_cache_clusters = 3
  }

  assert {
    condition     = output.rds_instance_identifier == "llmgw-litellm-db" && output.rds_instance_identifier == aws_db_instance.database.identifier
    error_message = "rds_instance_identifier must be the RDS instance identifier (app alarms use it as DBInstanceIdentifier)."
  }

  assert {
    condition     = output.redis_replication_group_id == "llmgw-redis" && output.redis_num_cache_clusters == 3
    error_message = "The Redis replication group ID and node count must be exported for the app's per-node alarms."
  }
}
