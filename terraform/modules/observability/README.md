# observability

CloudWatch alarms and one dashboard for the LiteLLM gateway (ECS Fargate behind an ALB, RDS PostgreSQL,
ElastiCache Redis). No custom code: every signal is an AWS service metric (ALB, ECS, Container Insights, RDS,
ElastiCache), plus one optional CloudWatch Logs metric filter on the LiteLLM JSON logs.

```hcl
module "observability" {
  source = "../modules/observability"

  deployment_name            = var.deployment_name
  alb_arn_suffix             = aws_lb.this.arn_suffix
  target_group_arn_suffix    = aws_lb_target_group.litellm.arn_suffix
  ecs_cluster_name           = aws_ecs_cluster.this.name
  ecs_service_name           = aws_ecs_service.litellm.name
  rds_instance_identifier    = var.rds_instance_identifier
  redis_replication_group_id = var.redis_replication_group_id
  redis_num_cache_clusters   = var.redis_num_cache_clusters
  log_group_name             = aws_cloudwatch_log_group.litellm.name
  alarm_email                = var.alarm_email
}
```

## Alarms

All alarm names are `<deployment_name>-<key>`. They notify the SNS topic on ALARM and OK.

| Key | Signal | Default |
|---|---|---|
| `alb-target-5xx-rate` | `100 * HTTPCode_Target_5XX_Count / RequestCount` (target group) | > 5 %, 2 of 3 periods, only with >= 10 requests per period |
| `alb-elb-5xx` | `HTTPCode_ELB_5XX_Count` | > 10 per period, 2 of 3 |
| `alb-latency-p90` | `TargetResponseTime` p90 | > 5 s, 2 of 3 |
| `alb-unhealthy-hosts` | `UnHealthyHostCount` max | > 0, 2 of 3 |
| `alb-no-healthy-hosts` | `HealthyHostCount` min | < 1, 2 of 2, missing data = breaching |
| `ecs-running-below-desired` | Container Insights `DesiredTaskCount - RunningTaskCount` | > 0 for 5 periods, missing data = breaching |
| `ecs-cpu-high` / `ecs-memory-high` | `AWS/ECS` service CPU / memory | > 80 %, 4 of 5 |
| `rds-cpu-high` | `CPUUtilization` | > 80 %, 4 of 5 |
| `rds-free-storage-low` | `FreeStorageSpace` | < 5 GiB |
| `rds-connections-high` | `DatabaseConnections` | > 100 (set this to about 80 % of `max_connections`) |
| `redis-engine-cpu-high` | `EngineCPUUtilization`, max across nodes | > 80 %, 4 of 5 |
| `redis-memory-high` | `DatabaseMemoryUsagePercentage`, max across nodes | > 80 %, 4 of 5 |
| `redis-evictions` | `Evictions`, max across nodes | > 0, 2 of 3 |
| `redis-connections-high` | `CurrConnections`, max across nodes | > 5000 |
| `redis-replication-lag` | `ReplicationLag`, max across nodes (only with 2+ nodes) | > 10 s |
| `log-errors` | Log metric filter `{ $.level = "ERROR" }` (when `enable_log_metrics`) | > 50 per period, 2 of 3 |

How missing data is treated depends on the alarm. `notBreaching` when no data just means no traffic or nothing
wrong (5XX, latency, evictions, log errors); `breaching` when the metric is always published while the service
exists (healthy hosts, running tasks); `missing` for periodic resource metrics.

Default thresholds: error rate > 5 % with 2 of 3 datapoints, and p90 latency > 5 s. There is no cost-per-request
alarm: cost is not an AWS metric, and LiteLLM does not log it (see below).

### Notes

- **Latency and streaming.** For streamed responses the ALB's `TargetResponseTime` lasts until the last byte, so it
  includes the whole generation time. The p90 alarm therefore tracks long completions, not only gateway slowness.
  Raise `latency_p90_threshold_seconds` if most traffic is streamed.
- **ElastiCache dimensions.** Node-based Redis metrics are published per `CacheClusterId` (and
  `CacheClusterId`+`CacheNodeId`), not per replication group. When cluster mode is disabled, the member clusters
  are `<replication_group_id>-001`, `-002`, and so on. The module derives these IDs from
  `redis_replication_group_id` and `redis_num_cache_clusters`, unless you set `redis_cache_cluster_ids`. It
  alarms on the `MAX()` across members, so the alarms keep working after a failover changes which node is primary.
- **Container Insights** must be enabled on the cluster. Otherwise `ecs-running-below-desired` goes into ALARM
  because its data is missing.
- **Encrypted topic.** When `alarm_sns_topic_arn` is null, the module creates an SNS topic encrypted with a
  dedicated customer managed KMS key. The AWS managed `alias/aws/sns` key cannot be used, because CloudWatch
  cannot publish to a topic encrypted with it. If you pass `kms_key_arn` or your own topic, its key policy must
  allow `cloudwatch.amazonaws.com` `kms:Decrypt` and `kms:GenerateDataKey*`.

## LiteLLM log metrics

Observed locally with `ghcr.io/berriai/litellm:v1.106.0`, `JSON_LOGS=True`, `LITELLM_LOG=INFO`,
`json_logs: true`, `turn_off_message_logging: true` and mock models:

- Each log line is a JSON object with the keys `message`, `level`, `timestamp`, `component` and `logger`. Some lines
  add extra keys such as `litellm_call_id`, `stacktrace` or `requester_ip`. The startup banner is not JSON, and
  the filter ignores it.
- An upstream provider failure (HTTP 500 to the client) logs one `"level": "ERROR"` line from
  `_handle_llm_api_exception`. A rejected API key logs one ERROR line from `user_api_key_auth`. Successful
  requests, streaming included, log only INFO lines.
- At INFO, LiteLLM logs no per-request cost, token or latency figures. That is why the module has no filters for
  them. Prompt text did not appear in the logs.

## Inputs

| Name | Description | Default |
|---|---|---|
| `deployment_name` | Prefix for every resource name | required |
| `tags` | Extra tags on taggable resources (provider `default_tags` already propagate) | `{}` |
| `alb_arn_suffix` | ALB ARN suffix (`LoadBalancer` dimension) | required |
| `target_group_arn_suffix` | LiteLLM target group ARN suffix (`TargetGroup` dimension) | required |
| `ecs_cluster_name` / `ecs_service_name` | ECS cluster and service | required |
| `rds_instance_identifier` | RDS `DBInstanceIdentifier` | required |
| `redis_replication_group_id` | Replication group ID; member `CacheClusterId`s are derived from it | required |
| `redis_num_cache_clusters` | Number of nodes in the replication group | `2` |
| `redis_cache_cluster_ids` | Explicit member `CacheClusterId`s (override) | `null` |
| `log_group_name` | LiteLLM container log group (required if `enable_log_metrics`) | `null` |
| `alarm_sns_topic_arn` | Existing topic; null creates an encrypted one | `null` |
| `alarm_email` | Optional email subscription | `null` |
| `kms_key_arn` | Key for the module-created topic; null creates one | `null` |
| `alarm_actions_enabled` | Send notifications | `true` |
| `enable_log_metrics` | Create the ERROR-count metric filter and alarm | `true` |
| `log_metric_namespace` | Namespace for the log metric | `LiteLLM/<deployment_name>` |
| `alarm_period_seconds` | Period for all alarms | `60` |
| threshold variables | `error_rate_threshold_percent`, `error_rate_min_requests`, `elb_5xx_threshold`, `latency_p90_threshold_seconds`, `ecs_cpu_threshold_percent`, `ecs_memory_threshold_percent`, `rds_cpu_threshold_percent`, `rds_free_storage_threshold_gib`, `rds_connections_threshold`, `redis_engine_cpu_threshold_percent`, `redis_memory_threshold_percent`, `redis_connections_threshold`, `redis_replication_lag_threshold_seconds`, `log_error_threshold` | see table above |

## Outputs

| Name | Description |
|---|---|
| `sns_topic_arn` | Topic receiving the notifications |
| `kms_key_arn` | Key created for the topic, or null |
| `alarm_names` | All alarm names |
| `alarm_arns` | All alarm ARNs (e.g. for composite alarms) |
| `dashboard_name` | Dashboard name (`<deployment_name>-gateway`) |
| `redis_cache_cluster_ids` | `CacheClusterId`s being monitored |
