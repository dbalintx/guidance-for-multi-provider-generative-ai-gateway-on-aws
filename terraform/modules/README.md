# Child modules

Shared child modules consumed by the two root modules (`terraform/foundation`,
`terraform/app`). Each lands on its own Milestone 1 branch:

- `vpc-validation/` — create-or-bring VPC; BYO subnets validated before anything is created
- `vpn/` — optional demo Client VPN (certificate auth, split tunnel, VPC range only)
- `observability/` — alarms, dashboard, SNS topic (AWS metrics only)

Rules (Milestone 1 contract): providers pinned in every module; `aws` (+
`random`/`tls` where needed) only — no helm, no kubernetes anywhere. Every
module ships `tests/*.tftest.hcl` with mocked providers covering its validation
rules and key wiring.
