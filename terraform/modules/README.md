# Child modules

Shared child modules consumed by the two root modules (`terraform/foundation`,
`terraform/app`):

- `vpn/` — optional demo Client VPN (certificate auth, split tunnel, VPC range
  only); called by foundation (`vpn.tf`) when `create_vpn = true`
- `observability/` — alarms, dashboard, SNS topic (AWS metrics only); called by
  app (`observability.tf`)

The create-or-bring VPC validation lives in the foundation itself
(`terraform/foundation/vpc-validation.tf`): it is plan-time locals and
preconditions only, so a module would add indirection without reuse.

Rules (Milestone 1 contract): providers pinned in every module; `aws` (+
`random`/`tls` where needed) only — no helm, no kubernetes anywhere. Every
module ships `tests/*.tftest.hcl` with mocked providers covering its validation
rules and key wiring.
