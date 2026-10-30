# The LiteLLM config.yaml, rendered by Terraform (no yq, no in-place edits).
# Layer 2 of 3: tfvars (infrastructure) -> this file (base config, read from S3
# at task start) -> LiteLLM's database (models, teams, keys, budgets — the UI).
# Its content hash lands in the task definition (container.tf), so any config
# change rolls the tasks.

data "aws_region" "current" {}

locals {
  config_object_key = "config.yaml"

  override = yamldecode(var.config_override_file != null ? file(var.config_override_file) : "{}")

  base_config = yamldecode(templatefile("${path.module}/templates/config-base.yaml.tftpl", {
    trusted_proxy_ranges = [var.vpc_cidr]
    request_log_bucket   = local.request_log_bucket_name
    region               = data.aws_region.current.region
  }))

  # Customer override: model_list entries are appended; the *_settings maps are
  # merged key-by-key over the base.
  litellm_config = merge(
    local.base_config,
    {
      model_list       = try(local.override.model_list, [])
      general_settings = merge(local.base_config.general_settings, try(local.override.general_settings, {}))
      litellm_settings = merge(local.base_config.litellm_settings, try(local.override.litellm_settings, {}))
      router_settings  = merge(local.base_config.router_settings, try(local.override.router_settings, {}))
    },
  )

  litellm_config_yaml = yamlencode(local.litellm_config)
  config_sha          = sha256(local.litellm_config_yaml)
}

resource "aws_s3_object" "litellm_config" {
  bucket       = var.config_bucket_name
  key          = local.config_object_key
  content      = local.litellm_config_yaml
  content_type = "application/yaml"
}

# Plan-time warnings (not errors), per 2.9 and 2.11.

check "debug_logging_is_temporary" {
  assert {
    condition     = var.log_level != "DEBUG"
    error_message = "log_level = DEBUG writes every prompt and response to CloudWatch (verified on 1.82.3 and 1.106.0). Use it for temporary troubleshooting only, then set it back to INFO."
  }
}

check "enterprise_settings_need_licence" {
  assert {
    condition     = var.litellm_license_secret_arn != null || !can(local.litellm_config.general_settings.enable_jwt_auth)
    error_message = "enable_jwt_auth is an Enterprise feature: without litellm_license_secret_arn LiteLLM answers 403 to JWTs (verified on 1.106.0)."
  }
}
