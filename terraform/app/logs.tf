# Log sinks owned by the app: the LiteLLM CloudWatch log group, the ALB access-log
# bucket and the LiteLLM request-log bucket (metadata only — message logging is
# off in the rendered config). 90-day retention by default (2.11); the buckets
# are kept on destroy while deletion_protection is on (2.14).

data "aws_caller_identity" "current" {}

locals {
  # Deterministic names: unique per deployment, account and region, and known at
  # plan time, so the rendered config (and its hash) shows up in the plan diff.
  access_log_bucket_name  = "${var.deployment_name}-alb-logs-${data.aws_caller_identity.current.account_id}-${data.aws_region.current.region}"
  request_log_bucket_name = "${var.deployment_name}-req-logs-${data.aws_caller_identity.current.account_id}-${data.aws_region.current.region}"
}

resource "aws_cloudwatch_log_group" "litellm" {
  name              = "/ecs/${var.deployment_name}-litellm"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
}

# --- ALB access logs. ALB log delivery only supports SSE-S3 (AES256), never KMS. ---

resource "aws_s3_bucket" "access_logs" {
  bucket        = local.access_log_bucket_name
  force_destroy = !var.deletion_protection
}

resource "aws_s3_bucket_server_side_encryption_configuration" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "access_logs" {
  bucket                  = aws_s3_bucket.access_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  rule {
    id     = "expire"
    status = "Enabled"

    filter {}

    expiration {
      days = var.log_retention_days
    }
  }
}

data "aws_elb_service_account" "main" {}

resource "aws_s3_bucket_policy" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnforceSSLOnly"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.access_logs.arn,
          "${aws_s3_bucket.access_logs.arn}/*",
        ]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
      {
        Sid       = "AllowELBLogDelivery"
        Effect    = "Allow"
        Principal = { AWS = data.aws_elb_service_account.main.arn }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.access_logs.arn}/*"
      },
    ]
  })
}

# --- LiteLLM request logs (the s3 callbacks in the rendered config). ---

resource "aws_s3_bucket" "request_logs" {
  bucket        = local.request_log_bucket_name
  force_destroy = !var.deletion_protection
}

resource "aws_s3_bucket_server_side_encryption_configuration" "request_logs" {
  bucket = aws_s3_bucket.request_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = var.kms_key_arn != null ? "aws:kms" : "AES256"
      kms_master_key_id = var.kms_key_arn
    }
  }
}

resource "aws_s3_bucket_public_access_block" "request_logs" {
  bucket                  = aws_s3_bucket.request_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "request_logs" {
  bucket = aws_s3_bucket.request_logs.id

  rule {
    id     = "expire"
    status = "Enabled"

    filter {}

    expiration {
      days = var.log_retention_days
    }
  }
}

resource "aws_s3_bucket_policy" "request_logs" {
  bucket = aws_s3_bucket.request_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnforceSSLOnly"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.request_logs.arn,
          "${aws_s3_bucket.request_logs.arn}/*",
        ]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
    ]
  })
}
