# LiteLLM (JSON_LOGS=True) writes one JSON object per line with a "level" field. Verified against
# ghcr.io/berriai/litellm:v1.106.0: upstream provider failures and auth failures log level=ERROR.
# Per-request cost and latency are NOT logged at INFO, so no filters are derived for them.
resource "aws_cloudwatch_log_metric_filter" "errors" {
  count = var.enable_log_metrics ? 1 : 0

  name           = "${var.deployment_name}-log-errors"
  log_group_name = var.log_group_name
  pattern        = "{ $.level = \"ERROR\" }"

  metric_transformation {
    name          = local.log_error_metric
    namespace     = local.log_metric_namespace
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}
