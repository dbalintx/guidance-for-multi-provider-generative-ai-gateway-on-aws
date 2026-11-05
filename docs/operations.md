# Operations

Day-2 procedures for a deployed gateway. Deployment itself is in [setup.md](setup.md); inputs are listed in
[reference.md](reference.md). The examples assume `deployment_name = "llmgw"` and:

```bash
OUT=deploy/.generated/llmgw-foundation-outputs.tfvars.json
```

- [How changes roll out](#how-changes-roll-out)
- [Upgrading LiteLLM](#upgrading-litellm)
- [Changing the LiteLLM configuration](#changing-the-litellm-configuration)
- [Generated secrets](#generated-secrets)
- [Temporary DEBUG logging](#temporary-debug-logging)
- [Adding the LiteLLM Enterprise licence](#adding-the-litellm-enterprise-licence)
- [Monitoring and alarms](#monitoring-and-alarms)
- [Backups and teardown](#backups-and-teardown)
- [Troubleshooting](#troubleshooting)

## How changes roll out

Every change is an edit to `deploy/terraform.tfvars` (or the files it points to) followed by
`deploy/deploy.sh`. Review the plan before confirming it. When the app's task definition changes (image,
environment, secrets or rendered config), the app apply:

1. uploads the rendered config to a new content-addressed object (`config-<sha16>.yaml`) in the config bucket;
   earlier objects are kept, so older task-definition revisions still load the config they were deployed with;
2. runs the schema migration as a one-off ECS task and fails unless it exits 0 (default wait 20 minutes; export
   `MIGRATION_TIMEOUT_SECONDS` before `deploy/deploy.sh` to allow longer). LiteLLM reports healthy on an
   unmigrated database, so the rollout is gated on the migration rather than on health checks;
3. rolls the ECS service. The deployment circuit breaker rolls back to the previous task definition if the new
   tasks do not become healthy.

The apply returns once the rollout has started, not when it has finished. Confirm the new tasks are running in
the ECS console (service **Deployments** tab) or with:

```bash
aws ecs describe-services --cluster llmgw-cluster --services llmgw-litellm \
  --query 'services[0].deployments[].{status:status,rollout:rolloutState,running:runningCount,desired:desiredCount}'
```

Models, keys, teams and budgets live in the database and are managed in the UI or API; they are not affected by
redeployments.

## Upgrading LiteLLM

The image is pinned by tag and by the digest of its multi-architecture index in `terraform/app/container.tf`.
To upgrade, change both:

```bash
docker buildx imagetools inspect ghcr.io/berriai/litellm:<new-tag>   # the "Digest:" line is the index digest
```

```hcl
image = coalesce(var.image_uri, "ghcr.io/berriai/litellm:<new-tag>@sha256:<index-digest>")
```

Then run `deploy/deploy.sh`; the migration runs before the new image serves traffic. Read the
[LiteLLM release notes](https://docs.litellm.ai/release_notes) first. When moving to another minor line, also
re-check the UI and login paths the load balancer protects (`ui_oidc_paths` in `terraform/app/alb.tf`), signal
handling, the schema migration and the log format.

With `image_uri` (a mirrored image), run `deploy/mirror-image.sh --version <new-tag>` and set the new printed
URI instead.

## Changing the LiteLLM configuration

Terraform renders LiteLLM's `config.yaml` from `terraform/app/templates/config-base.yaml.tftpl`. To change it,
point `config_override_file` at a YAML file of your own; its content is merged over the base:

- `general_settings`, `litellm_settings` and `router_settings` are merged key by key; your keys win;
- `model_list` and every other top-level key (for example `guardrails`) are taken from your file.

The setting names are LiteLLM's ([configuration reference](https://docs.litellm.ai/docs/proxy/configs)). The
plan shows the rendered config's diff, and every change rolls the tasks. The plan warns about
`allow_requests_on_db_unavailable: true` (LiteLLM then admits any key during a database outage) and about
`enable_jwt_auth` without a licence.

> **The response cache is on by default and shared across API keys.** The base config enables LiteLLM's Redis
> response cache: an identical request can return a response cached for another caller, and cached prompts and
> responses are stored in Redis. For multi-tenant or sensitive deployments, disable or tune it in the override
> file ([LiteLLM caching](https://docs.litellm.ai/docs/proxy/caching)):
>
> ```yaml
> litellm_settings:
>   cache: false
>   # or keep it on and make it opt-in per request, with a shorter TTL:
>   # cache_params: { type: redis, mode: default_off, ttl: 600, host: os.environ/REDIS_HOST,
>   #                 port: os.environ/REDIS_PORT, password: os.environ/REDIS_PASSWORD, ssl: true }
> ```
>
> `cache_params` replaces the base map as a whole, so keep the Redis connection keys when you override it.

> **Some incorrect settings do not fail task start-up.** LiteLLM starts and reports healthy with some broken
> settings; for example, an invalid cache port leaves the service healthy with a cache that does not work. After
> a configuration rollout, verify the feature you changed (for a cache change: send the same request twice and
> compare latency, or check the logs for Redis errors), not only the health checks.

Environment variables for LiteLLM go in `extra_environment` (plain values) and `provider_secret_arns` (Secrets
Manager references). Names the stack sets itself are rejected.

## Generated secrets

The foundation generates the master key, the salt key, the UI password, the Redis auth token and the database
password once, at the first deploy; the stack never rotates them. The salt key must never change: LiteLLM uses it
to encrypt the provider credentials stored in its database, and a new salt key would make them unreadable.

## Temporary DEBUG logging

Set `log_level = "DEBUG"` and run `deploy/deploy.sh`. At DEBUG, LiteLLM writes prompts and provider payloads to
CloudWatch Logs, so the plan warns while it is on. Set it back to `INFO` and deploy again as soon as you are done.
LiteLLM's own debugging options are described in its [debugging guide](https://docs.litellm.ai/docs/proxy/debugging).

## Adding the LiteLLM Enterprise licence

Without a licence LiteLLM runs its open-source feature set. To enable
[Enterprise features](https://docs.litellm.ai/docs/enterprise), store the licence key as a plain-text secret and
set its ARN:

```bash
aws secretsmanager create-secret --name llmgw-litellm-license --secret-string file://license.txt
```

```hcl
litellm_license_secret_arn = "arn:aws:secretsmanager:<region>:<account-id>:secret:llmgw-litellm-license-AbCdEf"
```

Run `deploy/deploy.sh`. LiteLLM checks the licence online, so the tasks need outbound access to LiteLLM's licence
server (see [No outbound internet access](setup.md#no-outbound-internet-access)).

## Monitoring and alarms

The app creates CloudWatch alarms on ALB, ECS, RDS and ElastiCache metrics and on LiteLLM ERROR log lines, a
dashboard (`<deployment_name>-gateway`) and an encrypted SNS topic. The alarms and their thresholds are listed in
the [observability module README](../terraform/modules/observability/README.md). Set `alarm_email` to subscribe an
address, then confirm the subscription from the email AWS sends.

Application Auto Scaling creates two more alarms per scaling policy (CPU and memory),
`TargetTracking-...-AlarmHigh` and `TargetTracking-...-AlarmLow`. On an idle service at its minimum of two tasks,
both AlarmLow alarms stay in ALARM indefinitely: they request a scale-in the service cannot make. This is
expected. They notify Application Auto Scaling only, never the alarm topic. Do not edit or delete them; target
tracking stops scaling without them until the policy is applied again.

LiteLLM's own spend and usage reporting is in its UI and [cost tracking](https://docs.litellm.ai/docs/proxy/cost_tracking).

## Backups and teardown

- **Database.** Automated backups are kept for 30 days (point-in-time restore in the RDS console). Every destroy
  takes a final snapshot (`<deployment_name>-litellm-db-final-<suffix>`) and keeps the automated backups, unless
  `destroy_data_without_snapshot = true` (throwaway deployments only).
- **Config.** The config bucket is versioned and every rendered config is kept under its own key.
- **Logs.** CloudWatch log groups and the access-log and request-log buckets retain data for ten years.

To remove a deployment, `deletion_protection` (the default `true`) must be lifted first; it protects the database
and the load balancer and keeps the buckets:

```bash
# 1. set deletion_protection = false in deploy/terraform.tfvars, then
deploy/deploy.sh
# 2. destroy the app, then the foundation (each plan asks for confirmation)
deploy/undeploy.sh
```

The Terraform state bucket is always kept; delete it yourself if no deployment uses it. Generated secrets enter a
seven-day recovery window. Snapshots and retained backups are billed until you delete them. The app alone can be
destroyed and redeployed at any time against a living foundation.

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| Tasks stop with `CannotPullContainerError` | No route to `ghcr.io` (no-internet mode, or a VPC without egress). [Mirror the image](setup.md#no-outbound-internet-access) and set `image_uri`. |
| App apply fails in the migration step | `run-migration.sh` prints the task's exit code or timeout; the migration logs are in the LiteLLM log group (`log_group_name` output). The service has not rolled. Fix the cause and deploy again; raise `MIGRATION_TIMEOUT_SECONDS` if the migration is only slow. |
| Apply finished but the old version still serves | The circuit breaker rolled back. Check the service events and the stopped tasks' reasons in the ECS console and the LiteLLM logs. |
| Every model call fails, the gateway is healthy | Bedrock model access is not enabled for that model and Region, the model is outside `bedrock_model_allowlist` / `bedrock_region_allowlist`, or the model ID or Region in the model definition is wrong. |
| A completion returns `finish_reason: "content_filter"` with no content | The model filtered an echo-style prompt; [use a natural question](setup.md#add-a-model). |
| Spend shows $0 for a model | The model is newer than the image's price list; [see Add a model](setup.md#add-a-model). |
| UI sign-in fails after the identity provider redirect | Redirect URI not registered as `https://<gateway-host>/oauth2/idpresponse`, wrong issuer or endpoints, or the load balancer cannot reach the provider (no-internet mode). |
| Log group or data store creation fails with a KMS error, or alarms never notify | The customer key policy is missing a grant; see [Customer managed KMS key](setup.md#customer-managed-kms-key-optional). |
| A non-ECS client times out connecting to Redis | Redis requires TLS and the auth token; use `rediss://`. |
| The VPN client cannot connect right after deploy | The Client VPN endpoint is not `available` yet; wait several minutes, then run `deploy/setup-vpn.sh profile` again. |
| Undeploy fails mentioning deletion protection | Set `deletion_protection = false`, run `deploy/deploy.sh`, then `deploy/undeploy.sh` again. |
| `Value for undeclared variable` warnings during plan | Expected: one tfvars file feeds both roots. |
