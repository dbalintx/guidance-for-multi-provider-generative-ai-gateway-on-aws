# RDS PostgreSQL: Multi-AZ, encrypted, deletion-protected by default, with a
# final snapshot, 30-day backups and changes applied in the maintenance window.
# The database logs schema changes and slow queries only — never every
# statement, which would send LiteLLM's spend logs, keys and team data to
# CloudWatch (ideation 2.11).

locals {
  db_username      = "llmproxy"
  db_name          = "litellm"
  db_major_version = split(".", var.db_engine_version)[0]
}

resource "random_password" "db" {
  length  = 16
  special = false # keeps the DATABASE_URL free of characters that need URL-encoding
}

resource "aws_db_subnet_group" "main" {
  name       = "${var.deployment_name}-db-subnet-group"
  subnet_ids = local.private_subnet_ids
}

resource "aws_db_parameter_group" "postgres" {
  name_prefix = "${var.deployment_name}-postgres${local.db_major_version}-"
  family      = "postgres${local.db_major_version}"

  parameter {
    name  = "log_statement"
    value = "ddl"
  }

  parameter {
    name  = "log_min_duration_statement"
    value = "5000"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# The final snapshot name carries a random suffix so destroy/redeploy cycles
# of the same deployment_name do not collide with an earlier snapshot.
resource "random_id" "final_snapshot" {
  byte_length = 4
}

resource "aws_db_instance" "database" {
  identifier     = "${var.deployment_name}-litellm-db"
  engine         = "postgres"
  engine_version = var.db_engine_version
  instance_class = var.rds_instance_class

  storage_type      = "gp3"
  allocated_storage = var.rds_allocated_storage
  storage_encrypted = true
  kms_key_id        = var.kms_key_arn

  db_name                = local.db_name
  username               = local.db_username
  password               = random_password.db.result
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.db.id]
  parameter_group_name   = aws_db_parameter_group.postgres.name
  multi_az               = true

  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = !var.deletion_protection
  final_snapshot_identifier = var.deletion_protection ? "${var.deployment_name}-litellm-db-final-${random_id.final_snapshot.hex}" : null
  backup_retention_period   = var.db_backup_retention_days
  copy_tags_to_snapshot     = true
  apply_immediately         = false # changes wait for the maintenance window

  enabled_cloudwatch_logs_exports = ["postgresql"]
  auto_minor_version_upgrade      = true
  monitoring_interval             = 60
  monitoring_role_arn             = aws_iam_role.rds_enhanced_monitoring.arn

  performance_insights_enabled    = true
  performance_insights_kms_key_id = var.kms_key_arn
}
