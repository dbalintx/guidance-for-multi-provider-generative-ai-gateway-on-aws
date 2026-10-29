# Decision log

Deltas against `gateway-technical-ideation.md` (2026-10-19). Where they conflict, this log wins.

## 2026-10-29 — Milestones

**Milestone 1 (now):** the core changes (sections 2.1–2.18 of the ideation doc, plus the follow-ups 5.1 and 5.2), with two pieces pulled forward from the CI work because they protect Milestone 1 itself:
- committed Terraform provider lock files (providers pinned)
- the smoke-test script

**Milestone 2 (second step):**
- CI quality gates (2.19): fmt/validate/tftest, tflint, checkov, gitleaks, shellcheck, Renovate
- Documentation (2.20): README, Setup guide, Maintenance guide, input reference
- AgentCore integration guidance: a guide + minimal client-side example for Bedrock AgentCore agents invoking LLMs through the gateway (Strands' OpenAI-compatible/LiteLLM provider, AgentCore Runtime in VPC mode, auth via virtual key or IdP client-credentials JWT). Not part of the gateway or its request path. AgentCore Gateway (the MCP/tool gateway) is a different product and out of scope.
- The minimal EKS example (below)

## 2026-10-29 — IdP sign-in: always on, in both modes

Supersedes 2.5's "required in public mode, recommended in private": when an identity provider is configured, the ALB OIDC sign-in in front of the LiteLLM UI is applied **unconditionally, in private and public mode alike**. The public/private × sign-in combination validations are dropped.

One technical constraint remains: the ALB OIDC action requires HTTPS, so the HTTP-only private trial cannot have it and keeps LiteLLM's own admin login.

## 2026-10-29 — EKS: removed from the stack, replaced by a minimal example (Milestone 2)

EKS is removed from the main Terraform stack as planned (2.3). Stakeholders still want an EKS option, agreed as a **starting-point example, explicitly not production-grade** — it only proves the gateway runs on EKS:

- Lives outside the main stack (e.g. `examples/eks/`): ~200–300 lines of plain Kubernetes manifests (official LiteLLM image, same env vars as ECS) plus a short setup script/doc. No Helm chart dependency, no helm/kubernetes Terraform providers anywhere in the stack.
- **Bring your own cluster.** The example never creates or upgrades an EKS cluster, its addons or its load-balancer controller.
- It consumes the foundation's outputs (DB endpoint, Redis, config bucket, secret ARNs); the setup script creates the K8s Secret from Secrets Manager values and applies the manifests.
- The only touch point on the main stack is one **generic** input: an extra security group / CIDR allowed to reach RDS and Redis (useful for any external client, not EKS-specific).
- Documented gaps, one page: no ALB OIDC sign-in, no WAF, no migration-gated rollout, no alarms, no autoscaling or drain tuning. The production-grade path is ECS.
- Maintenance: the image tag in one manifest, bumped with the ECS one; "does it still deploy" is a periodic manual check, best-effort.

### Standing constraint on Milestone 1 ("EKS-example compatibility")

Everything implemented in Milestone 1 must stay pluggable for this example, so Milestone 2 needs no rework. Concretely:

1. The **foundation** (network, data) must contain nothing ECS-specific, and must export as outputs what a non-ECS consumer needs: DB endpoint/URL secret, Redis endpoint + auth secret, config bucket/key, master-key and salt-key secret ARNs.
2. The foundation accepts the generic extra-ingress input (security group ID and/or CIDR) on the RDS and Redis security groups.
3. The rendered LiteLLM `config.yaml` must not depend on ECS specifics — the same rendered file must be loadable from S3 (or as a ConfigMap) by a pod.
4. Container settings (env vars, ports, health-check path, stop-signal behaviour) live in one obvious place, so the manifests can mirror them.
5. Nothing in scripts or validation may assume ECS is the only possible client of the data stores.

## Earlier decisions (from the stakeholder proposal round, 2026-10-22..28)

- **ECR image pre-loading** (mirror + signature verification + digest pinning) moved **below the line**; the current method, a pinned upstream LiteLLM version tag, stays.
- **Foundation/app stack split** moved **in scope** (it also underpins the EKS example above).
- The breaking-changes list is kept out of the stakeholder proposal but still applies: middleware features removed (server-side chat history, prompt ARNs), CloudFront/EKS deployments must migrate, BYO-VPC users must list subnets, provider keys move to Secrets Manager ARNs.
- Below the line (on stakeholder demand only): EKS beyond the starting-point example ("port + re-harden + re-load-test"), CloudFront in front of the public ALB, ECR image pre-loading, CI smoke test against a throwaway deployment, private load-test harness, observability integrations via LiteLLM callbacks.
