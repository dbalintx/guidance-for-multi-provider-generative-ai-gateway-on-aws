# rollout

The two steps an app apply runs with the AWS CLI, in order:

1. `deploy/put-config.sh`: uploads the rendered LiteLLM config to its content-addressed key
   (`config-<sha16>.yaml`). Earlier keys are never deleted, so every task-definition revision can still load
   its own config.
2. `deploy/run-migration.sh`: runs the schema migration as a one-off ECS task and fails the apply unless it
   exits 0 (`MIGRATION_TIMEOUT_SECONDS`, default 1200, bounds the wait).

The app root calls it unconditionally and makes the ECS service depend on it. Tests must replace it with
`override_module { target = module.rollout }`: a `local-exec` provisioner runs even when its resource is
overridden, and both scripts call AWS.
