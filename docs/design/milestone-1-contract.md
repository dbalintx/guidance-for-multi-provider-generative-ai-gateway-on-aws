# Milestone 1 interface contract

Binding for every Milestone 1 branch. The requirements are `gateway-technical-ideation.md` as amended by `decisions.md` (the decision log wins on conflict). The POC branch `reference/geh-hardening-poc` is **reference material, not ground truth**: port what is good, replace what has a better solution, but never deviate from the requirements or from this contract without flagging it in your report.

## Repository layout

```
terraform/
  foundation/          # root module 1: long-lived network + data. Own state.
  app/                 # root module 2: gateway + monitoring. Own state.
  modules/<name>/      # child modules (vpc-validation, vpn, observability, ...)
deploy/                # deploy.sh, undeploy.sh, smoke-test.sh, setup-vpn.sh, terraform.tfvars.example
docs/
  design/              # these documents
  fresh-account-notes.md
```

The legacy `litellm-terraform-stack/`, `middleware/`, EKS paths, root-level `*.sh` and middleware test suites are removed in the base branch. The fake-LLM load-test Terraform and `litellm-s3-log-bucket-terraform` stay untouched for now.

## The two root modules

**foundation** (create-or-bring VPC, validated; RDS PostgreSQL Multi-AZ; ElastiCache Redis; S3 config bucket; Secrets Manager secrets; optional customer KMS key; optional demo Client VPN). Changes rarely; an app upgrade must never touch it.

**app** (ALB + listeners + optional WAF + optional OIDC; ECS cluster/service/task + migration task; rendered LiteLLM config; observability). Destroyable and re-deployable against a living foundation at any time.

**Coupling rule:** `app` consumes `foundation` only through plain input variables. No `terraform_remote_state`, no provider aliases crossing the boundary. The deploy script wires `terraform output -json` from foundation into app's variables. This is what later lets the EKS example (Milestone 2) consume the same outputs.

## Foundation outputs (the EKS-compatibility surface — decisions.md)

At minimum: `vpc_id`, `private_subnet_ids`, `vpc_cidr`, `db_endpoint`, `database_url_secret_arn`, `redis_endpoint`, `redis_port`, `redis_auth_secret_arn`, `config_bucket_name`, `master_key_secret_arn`, `salt_key_secret_arn`, `kms_key_arn` (null when not used), `data_ingress_security_group_id` (the SG whose membership grants RDS+Redis access).

Foundation inputs include the generic **extra ingress** hook: `extra_data_ingress_security_group_ids` (list) and `extra_data_ingress_cidrs` (list) admitted to RDS and Redis. Nothing in foundation may reference ECS, the ALB, or any app concept.

## App contract

- **Container settings in one place:** a single `locals` block (or one file) defines image URI + tag, port (4000), environment map, secrets map, health-check command/path, stop timeout. The Milestone 2 EKS example mirrors this block; do not scatter it.
- **Config:** Terraform renders `config.yaml` (templatefile), uploads to the foundation config bucket, and injects the content hash into the task definition so a config change rolls tasks. Rendered config must contain nothing ECS-specific.
- **Modes** (inputs): `public_mode` (bool, default false); `certificate_arn`; `allow_insecure_http` (private trials only — **rejected when `public_mode`**); optional `hosted_zone_id` + `record_name` (name without zone, or zone without name, is rejected); optional `identity_provider` object (issuer/endpoints, client_id, client_secret → ALB OIDC on UI paths **unconditionally in both modes when set**; no public/private sign-in combination validations — decisions.md); optional `litellm_license_secret_arn`.
- Idle timeout, target deregistration delay and ECS `stopTimeout` aligned at 120 s; deployment circuit breaker with rollback; task count left to autoscaling; migration as a one-off task definition (`--skip_server_startup`), service tasks run `DISABLE_SCHEMA_UPDATE=true`. Never `--max_requests_before_restart`.
- LiteLLM: official upstream image, pinned stable version tag (verify the current stable; POC used 1.106.0). No image mirror/signature tooling (below the line).

## Cross-cutting rules

- **Naming/tags:** every resource name derives from `var.deployment_name`; `default_tags` on the provider + `var.tags` passthrough. Two deployments in one account must not collide.
- **Secrets:** values never in variables, state or output; inputs take Secrets Manager ARNs. Generated secrets (master key, salt key, Redis auth, UI password) use 7-day recovery windows. No secret ever printed by a script.
- **Logging:** LiteLLM at INFO, JSON, message logging off on all callbacks; DB logs schema changes + slow queries only; 90-day retention defaults.
- **IAM:** task role = Bedrock inference + guardrails only (+ optional model/region allowlists), write-only logs bucket, read-only config object; no `*` policies anywhere.
- **Providers:** `aws` (+ `random`/`tls` where needed) only — **no helm, no kubernetes anywhere**. Versions pinned in every root/child module; `.terraform.lock.hcl` committed for both root modules (Milestone 1 scope — decisions.md).
- **No custom code in the request path.** No sidecars, no wrappers, no LiteLLM patches.

## Quality bar (every branch)

1. `terraform fmt -check` and `terraform validate` clean on both root modules.
2. Every module you create or change has `tests/*.tftest.hcl` with mocked providers covering its validation rules and key wiring; paste the real `terraform test` summary (N passed) in your report.
3. Shell scripts pass `shellcheck` untouched by directives; scripts take no secrets as arguments and echo none.
4. No resource destroyed/created by renaming without a `moved` block where state continuity is feasible.
5. Anything you could not verify is listed in your report as unverified — never implied as covered.

## Fresh-account notes

Any prerequisite or gotcha a user would hit deploying into a brand-new AWS account (state bootstrap, service-linked roles, Bedrock model access, quotas, region enablement) goes into `docs/fresh-account-notes.md` the moment it is discovered — scripts may automate a prerequisite, but the note still records it.
