# Container settings live in this ONE block (Milestone 1 contract): the ECS task
# definition, the migration task and the Milestone 2 EKS example all mirror it.
# Do not scatter image, port, env, secrets or health-check settings elsewhere.
locals {
  container = {
    # Official upstream image, pinned stable version tag. v1.106.0 is the
    # version the GEH hardening POC verified (signature, migration, logging);
    # re-verify the current stable before bumping.
    image = "ghcr.io/berriai/litellm:v1.106.0"
    port  = 4000

    # Plain environment values. Service tasks must run DISABLE_SCHEMA_UPDATE=true;
    # only the one-off migration task (--skip_server_startup) migrates.
    environment = {
      DISABLE_SCHEMA_UPDATE = "true"
    }

    # name -> Secrets Manager ARN; values are injected by the runtime, never by Terraform.
    secrets = {}

    # TODO(m1 ecs branch): the POC-verified liveliness command against this path.
    health_check_path = "/health/liveliness"

    # Aligned at 120 s with the ALB idle timeout and target deregistration delay.
    stop_timeout = 120
  }
}
