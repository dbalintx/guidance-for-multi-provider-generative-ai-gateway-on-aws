# Generated secrets, in Secrets Manager only: values never appear in variables
# or outputs. The generated values do live in this root
# module's Terraform state — keep the state bucket encrypted and private
# (deploy/deploy.sh creates it that way). Deleted secrets keep a recovery
# window (7 days by default).

# LiteLLM master key: the break-glass admin credential. The UI gets its own
# password below so the master key is never used for routine sign-in.
resource "random_password" "master_key" {
  length  = 21
  special = false
}

resource "aws_secretsmanager_secret" "master_key" {
  name_prefix             = "${var.deployment_name}-master-key-"
  description             = "LiteLLM master key (sk-...)"
  recovery_window_in_days = var.secret_recovery_window_days
  kms_key_id              = var.kms_key_arn
}

resource "aws_secretsmanager_secret_version" "master_key" {
  secret_id     = aws_secretsmanager_secret.master_key.id
  secret_string = "sk-${random_password.master_key.result}"
}

# The salt key encrypts provider credentials stored in LiteLLM's database.
# NEVER rotate it: rotation makes those stored credentials unreadable.
resource "random_password" "salt_key" {
  length  = 21
  special = false
}

resource "aws_secretsmanager_secret" "salt_key" {
  name_prefix             = "${var.deployment_name}-salt-key-"
  description             = "LiteLLM salt key - never rotate it"
  recovery_window_in_days = var.secret_recovery_window_days
  kms_key_id              = var.kms_key_arn
}

resource "aws_secretsmanager_secret_version" "salt_key" {
  secret_id     = aws_secretsmanager_secret.salt_key.id
  secret_string = "sk-${random_password.salt_key.result}"
}

# Redis auth token (generated in redis.tf, consumed by LiteLLM's router).
resource "aws_secretsmanager_secret" "redis_auth" {
  name_prefix             = "${var.deployment_name}-redis-auth-"
  description             = "ElastiCache Redis auth token"
  recovery_window_in_days = var.secret_recovery_window_days
  kms_key_id              = var.kms_key_arn
}

resource "aws_secretsmanager_secret_version" "redis_auth" {
  secret_id     = aws_secretsmanager_secret.redis_auth.id
  secret_string = random_password.redis_auth.result
}

# Without UI_PASSWORD, LiteLLM accepts the master key as the admin UI password.
# A separate password keeps the master key break-glass only.
resource "random_password" "ui_password" {
  length  = 24
  special = false
}

resource "aws_secretsmanager_secret" "ui_password" {
  name_prefix             = "${var.deployment_name}-ui-password-"
  description             = "LiteLLM admin UI password (separate from the master key)"
  recovery_window_in_days = var.secret_recovery_window_days
  kms_key_id              = var.kms_key_arn
}

resource "aws_secretsmanager_secret_version" "ui_password" {
  secret_id     = aws_secretsmanager_secret.ui_password.id
  secret_string = random_password.ui_password.result
}

# The full DATABASE_URL, so consumers need one secret, not credentials plus
# endpoint assembly. The password is generated without special characters, so
# no URL-encoding is needed.
resource "aws_secretsmanager_secret" "database_url" {
  name_prefix             = "${var.deployment_name}-database-url-"
  description             = "Full postgresql:// DATABASE_URL for LiteLLM"
  recovery_window_in_days = var.secret_recovery_window_days
  kms_key_id              = var.kms_key_arn
}

resource "aws_secretsmanager_secret_version" "database_url" {
  secret_id     = aws_secretsmanager_secret.database_url.id
  secret_string = "postgresql://${local.db_username}:${random_password.db.result}@${aws_db_instance.database.endpoint}/${local.db_name}"
}
