# The AWS side of the EKS example: the rendered LiteLLM config (delivered to
# the pods as a ConfigMap by scripts/deploy.sh), the request-log bucket its s3
# callbacks write to, and the pods' IAM role (iam.tf). Nothing here touches the
# cluster's configuration or the gateway's stacks.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  account_id  = data.aws_caller_identity.current.account_id
  region      = data.aws_region.current.region
  partition   = data.aws_partition.current.partition
  cluster_arn = "arn:${local.partition}:eks:${local.region}:${local.account_id}:cluster/${var.cluster_name}"

  request_log_bucket_name = "${var.name}-req-logs-${local.account_id}-${local.region}"

  # The same template, variables and encoding as terraform/app/config.tf, so
  # the pods load the configuration the ECS tasks load (minus the ECS
  # deployment's own request-log bucket and config_override_file).
  litellm_config_yaml = yamlencode(yamldecode(templatefile("${path.module}/../../../terraform/app/templates/config-base.yaml.tftpl", {
    trusted_proxy_ranges = [var.vpc_cidr]
    request_log_bucket   = local.request_log_bucket_name
    region               = local.region
  })))
  config_sha = sha256(local.litellm_config_yaml)
}

# --- LiteLLM request logs (the s3 callbacks in the rendered config). ---
# Emptied and deleted on teardown: this example keeps no long-term audit trail.

resource "aws_s3_bucket" "request_logs" {
  bucket        = local.request_log_bucket_name
  force_destroy = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "request_logs" {
  bucket = aws_s3_bucket.request_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = var.kms_key_arn != null ? "aws:kms" : "AES256"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = var.kms_key_arn != null
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
      days = var.request_log_retention_days
    }
  }
}

resource "aws_s3_bucket_policy" "request_logs" {
  bucket = aws_s3_bucket.request_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "EnforceSSLOnly"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.request_logs.arn, "${aws_s3_bucket.request_logs.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })

  depends_on = [aws_s3_bucket_public_access_block.request_logs]
}
