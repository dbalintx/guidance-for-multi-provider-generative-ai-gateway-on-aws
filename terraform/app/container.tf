# Container settings live in this ONE block: the ECS task definition and the
# migration task are built from it, and any non-ECS runtime can mirror it.
# Do not scatter image, port, env, secrets or health-check settings elsewhere.
locals {
  container = {
    # Official upstream image at the pinned upstream release; update it
    # deliberately, and re-check signal handling, the schema migration and the
    # log format when moving to another minor line.
    # image_uri overrides it for air-gapped deployments that mirrored the image
    # into a private registry (for example the account's ECR).
    image = coalesce(var.image_uri, "ghcr.io/berriai/litellm:v1.106.6")
    port  = 4000

    # Plain environment values (secrets never go here). Service tasks must run
    # DISABLE_SCHEMA_UPDATE=true: only the one-off migration task (which flips it
    # and passes --skip_server_startup) migrates the schema.
    environment = merge(
      {
        LITELLM_LOG                      = var.log_level # LiteLLM writes prompts at DEBUG; INFO is the default
        JSON_LOGS                        = "True"
        LITELLM_CONFIG_BUCKET_NAME       = var.config_bucket_name
        LITELLM_CONFIG_BUCKET_OBJECT_KEY = local.config_object_key
        LITELLM_CONFIG_SHA               = local.config_sha # a config change makes a new revision, so a rolling deploy
        UI_USERNAME                      = "admin"
        REDIS_HOST                       = var.redis_endpoint
        REDIS_PORT                       = tostring(var.redis_port)
        REDIS_SSL                        = "True"
        DISABLE_SCHEMA_UPDATE            = "true"
        LITELLM_LOCAL_MODEL_COST_MAP     = "True" # no start-up fetch from raw.githubusercontent.com
      },
      var.extra_environment,
    )

    # name -> Secrets Manager ARN; values are injected by the runtime, never by Terraform.
    secrets = merge(
      {
        DATABASE_URL       = var.database_url_secret_arn
        LITELLM_MASTER_KEY = var.master_key_secret_arn
        LITELLM_SALT_KEY   = var.salt_key_secret_arn
        REDIS_PASSWORD     = var.redis_auth_secret_arn
        UI_PASSWORD        = var.ui_password_secret_arn # separate from the master key
      },
      # Reduced mode without a licence; Enterprise features need LITELLM_LICENSE (no rebuild to switch).
      var.litellm_license_secret_arn != null ? { LITELLM_LICENSE = var.litellm_license_secret_arn } : {},
      var.provider_secret_arns,
    )

    # Liveliness probe (python3 ships in the image); the ALB target group checks the same path.
    health_check_path    = "/health/liveliness"
    health_check_command = ["CMD-SHELL", "python3 -c \"import urllib.request; urllib.request.urlopen('http://localhost:4000/health/liveliness', timeout=5)\" || exit 1"]

    # Aligned at 120 s (Fargate's maximum) with the ALB idle timeout and the
    # target deregistration delay: in-flight streams get this long to finish.
    stop_timeout = 120
  }
}
