# Config bucket: versioned (a bad config can be rolled back), private, TLS-only,
# kept on destroy while deletion protection is on. The app root module renders the LiteLLM
# config (one content-addressed config-<sha16>.yaml per change) and uploads it
# here — the foundation only provides the bucket.

resource "aws_s3_bucket" "config" {
  bucket_prefix = "${var.deployment_name}-config-"
  force_destroy = !var.deletion_protection
}

resource "aws_s3_bucket_versioning" "config" {
  bucket = aws_s3_bucket.config.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "config" {
  bucket = aws_s3_bucket.config.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = var.kms_key_arn != null ? "aws:kms" : "AES256"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = var.kms_key_arn != null
  }
}

resource "aws_s3_bucket_public_access_block" "config" {
  bucket                  = aws_s3_bucket.config.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "config" {
  bucket     = aws_s3_bucket.config.id
  depends_on = [aws_s3_bucket_public_access_block.config]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "EnforceSSLOnly"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource = [
        aws_s3_bucket.config.arn,
        "${aws_s3_bucket.config.arn}/*",
      ]
      Condition = {
        Bool = { "aws:SecureTransport" = "false" }
      }
    }]
  })
}

# The app writes one content-addressed config object per change and never
# deletes earlier ones, so every task-definition revision can still load its
# own config. Only noncurrent versions (overwritten or deleted objects) expire;
# current objects never do, which would remove a live config.
resource "aws_s3_bucket_lifecycle_configuration" "config" {
  bucket = aws_s3_bucket.config.id

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.config]
}


# S3 server access logs of the config bucket (who read or wrote which config).
# A dedicated bucket: a log target must not log to itself, and S3 server access
# logging supports only SSE-S3 on the target bucket. Kept on destroy while
# deletion protection is on, like the config bucket.
resource "aws_s3_bucket" "s3_access_logs" {
  bucket_prefix = "${var.deployment_name}-s3-access-logs-"
  force_destroy = !var.deletion_protection
}

resource "aws_s3_bucket_server_side_encryption_configuration" "s3_access_logs" {
  bucket = aws_s3_bucket.s3_access_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256" # the only encryption S3 server access logging delivers to
    }
  }
}

resource "aws_s3_bucket_public_access_block" "s3_access_logs" {
  bucket                  = aws_s3_bucket.s3_access_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "s3_access_logs" {
  bucket = aws_s3_bucket.s3_access_logs.id

  rule {
    object_ownership = "BucketOwnerEnforced" # delivery is granted by bucket policy, not ACLs
  }
}

resource "aws_s3_bucket_policy" "s3_access_logs" {
  bucket     = aws_s3_bucket.s3_access_logs.id
  depends_on = [aws_s3_bucket_public_access_block.s3_access_logs]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnforceSSLOnly"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.s3_access_logs.arn,
          "${aws_s3_bucket.s3_access_logs.arn}/*",
        ]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      },
      {
        # Only S3 logging, only for this deployment's config bucket, only in this account.
        Sid       = "AllowS3ServerAccessLogDelivery"
        Effect    = "Allow"
        Principal = { Service = "logging.s3.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.s3_access_logs.arn}/config/*"
        Condition = {
          ArnLike      = { "aws:SourceArn" = aws_s3_bucket.config.arn }
          StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
        }
      },
    ]
  })
}

resource "aws_s3_bucket_lifecycle_configuration" "s3_access_logs" {
  bucket = aws_s3_bucket.s3_access_logs.id

  rule {
    id     = "expire-access-logs"
    status = "Enabled"

    filter {}

    expiration {
      days = local.log_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_logging" "config" {
  bucket        = aws_s3_bucket.config.id
  target_bucket = aws_s3_bucket.s3_access_logs.id
  target_prefix = "config/"

  depends_on = [aws_s3_bucket_policy.s3_access_logs]
}
