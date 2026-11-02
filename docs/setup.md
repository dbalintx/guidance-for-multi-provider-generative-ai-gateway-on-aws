# Setup

This page takes you from an empty AWS account to a verified gateway. Day-2 tasks are in
[operations.md](operations.md); every input is listed in [reference.md](reference.md).

> **Breaking change.** Version 2 of this Guidance replaces the previous version (its middleware, Amazon CloudFront
> distribution, Amazon EKS option and bastion host are gone). There is no in-place upgrade and no Terraform state
> migration: deploy version 2 as a new deployment, recreate or migrate your LiteLLM data (models, teams, keys),
> move clients over, then remove the old deployment.

- [Prerequisites](#prerequisites)
- [Choose a deployment](#choose-a-deployment)
- [Trial deployment](#trial-deployment)
- [Private production deployment](#private-production-deployment)
- [Public deployment](#public-deployment)
- [Identity provider](#identity-provider)
- [Sign in to the UI](#sign-in-to-the-ui)
- [Verify and add a first model](#verify-and-add-a-first-model)

## Prerequisites

### Regions

Any commercial AWS Region (the `aws` partition) where Amazon Bedrock and the services in the
[architecture](../README.md#architecture) are available. AWS GovCloud (US) and the China Regions are not
supported. Opt-in Regions must be enabled on the account first. The created VPC uses the first two available
Availability Zones; a Region with fewer than two usable zones cannot be used.

### Tools

On the machine that runs the deployment:

- Terraform 1.11 or later (the generated secrets use write-only arguments).
- The AWS CLI and `jq`. The app apply calls the AWS CLI itself to upload the LiteLLM config and to run the
  schema migration task.
- `openssl`, for the demo Client VPN certificates.
- Docker and `cosign`, only to mirror the image (`deploy/mirror-image.sh`).

### Credentials and permissions

Run the scripts with credentials for the target account and set the Region with `AWS_REGION` (or a default
Region in the AWS CLI configuration). Besides permissions for the resources themselves, the deploying principal
needs:

- `iam:CreateServiceLinkedRole`: the first use of Amazon ECS, ElastiCache, RDS, Elastic Load Balancing or Client
  VPN in an account creates their service-linked roles.
- `iam:CreateRole`, `iam:AttachRolePolicy`, `iam:PassRole` for the roles the stack creates (ECS task and
  execution roles, RDS Enhanced Monitoring role, VPC flow logs role).
- For the app apply: `s3:PutObject` on the config bucket, `ecs:RunTask`, `ecs:DescribeTasks`, `ecs:StopTask`,
  and `iam:PassRole` on the two task roles.
- In public mode, for WAF logging: `logs:CreateLogDelivery`, `logs:PutResourcePolicy`,
  `logs:DescribeResourcePolicies` and `logs:DescribeLogGroups`.

### Terraform state

`deploy/deploy.sh` keeps state in an S3 bucket named `litellm-gateway-tfstate-<account-id>-<region>` (override
with `TF_STATE_BUCKET`) and creates it on the first run: versioning on, SSE-S3 encryption, public access blocked,
bucket-owner-enforced ownership, TLS-only bucket policy, and native S3 state locking (no DynamoDB table). Each
deployment's state lives under `<deployment_name>/`. The scripts refuse a bucket of that name owned by another
account. Creating the bucket needs `s3:CreateBucket`, `s3:PutBucketVersioning`, `s3:PutEncryptionConfiguration`,
`s3:PutBucketPublicAccessBlock`, `s3:PutBucketOwnershipControls`, `s3:PutBucketPolicy`, plus `s3:ListBucket`,
object read and write on the bucket, and `sts:GetCallerIdentity`.

### Amazon Bedrock model access

A new account has access to no foundation models. Enable model access in the Amazon Bedrock console for the
models and Regions you will use (some providers require a use-case form). Without it the gateway deploys and every
model call fails.

### Service quotas

Check these default quotas before the first deployment: Elastic IP addresses (one for the NAT gateway), VPCs per
Region, Application Load Balancers per Region, and Fargate On-Demand vCPUs (two tasks of 2 vCPU at minimum, up to
20 tasks when scaling out).

### Customer managed KMS key (optional)

With `kms_key_arn` set, the database, Redis, Secrets Manager secrets, CloudWatch log groups, the config and
request-log buckets and the alarm topic are encrypted with your key. Terraform does not manage the key policy;
it must allow:

- the deploying principal to use the key;
- `logs.<region>.amazonaws.com` `kms:Encrypt*`, `kms:Decrypt*`, `kms:GenerateDataKey*` and `kms:Describe*`
  (otherwise creating the log groups fails with `AccessDeniedException`);
- `cloudwatch.amazonaws.com` `kms:Decrypt` and `kms:GenerateDataKey*`, so alarms can publish to the encrypted
  topic (without it the deploy succeeds but no alarm notification is delivered);
- RDS and ElastiCache to use the key (they fail at creation with a KMS error otherwise).

Secrets you create yourself (identity provider client secret, licence, provider API keys) must be encrypted with
the AWS managed key `aws/secretsmanager` or with this same key; the task execution role can decrypt no other key.
With `kms_key_arn = null` AWS managed keys are used and no key policy work is needed.

## Choose a deployment

| | Trial | Private production | Public |
| --- | --- | --- | --- |
| Load balancer | Internal | Internal | Internet-facing, AWS WAF |
| Protocol | Plain HTTP | HTTPS (your ACM certificate) | HTTPS (your ACM certificate) |
| Client access | Demo Client VPN | Your VPN, Direct Connect or Transit Gateway | Internet |
| Identity provider | Not available (needs HTTPS) | Recommended | Strongly recommended |

All three use the same scripts and one input file. Copy the example and edit it:

```bash
cp deploy/terraform.tfvars.example deploy/terraform.tfvars
```

`deployment_name` (default `llmgw` in the example) prefixes every resource; use a different name for each
deployment in an account. Secrets never go in this file: secret inputs are Secrets Manager ARNs.

`deploy/deploy.sh` plans and applies the foundation, then the app, asking for confirmation before each apply
(`--auto-approve` skips the prompts). It prints the gateway URL at the end.

## Trial deployment

A private gateway on plain HTTP, reached through a demo AWS Client VPN. Use it to explore LiteLLM, not for
production traffic.

> **The trial is plain HTTP and reachable only through the VPN.** `allow_insecure_http` cannot be combined with
> public mode or an identity provider; move to [private production](#private-production-deployment) before real
> use.

1. Create the VPN certificates and import them into ACM. Use the `deployment_name` from your tfvars:

   ```bash
   deploy/setup-vpn.sh certs --name llmgw --region <region>
   ```

   The script creates a local CA, a server certificate and one shared client certificate (RSA 2048; Client VPN
   accepts only RSA 1024 or 2048) under `~/.llm-gateway-vpn/<name>/`, imports them into ACM and prints the
   certificate ARNs. Private keys stay on your machine and in ACM, never in Terraform state.

2. Set in `deploy/terraform.tfvars`:

   ```hcl
   deployment_name     = "llmgw"
   allow_insecure_http = true
   deletion_protection = false # optional: lets deploy/undeploy.sh remove the trial in one step

   create_vpn                      = true
   vpn_server_certificate_arn      = "arn:aws:acm:..." # printed by setup-vpn.sh certs
   vpn_client_root_certificate_arn = "arn:aws:acm:..." # printed by setup-vpn.sh certs
   ```

   VPN clients get addresses from `vpn_client_cidr` (default `10.250.0.0/22`), which must not overlap the VPC.

3. Deploy:

   ```bash
   deploy/deploy.sh
   ```

4. Wait until the Client VPN endpoint is `available` (several minutes after the apply returns), then write the
   VPN profile and import it into an OpenVPN-compatible client (AWS VPN Client, Tunnelblick or `openvpn`; the
   script detects which one is installed and prints the import steps):

   ```bash
   deploy/setup-vpn.sh profile --name llmgw --region <region>
   ```

   The `.ovpn` file contains the shared client private key; do not share or commit it. The VPN is split-tunnel
   and authorised for the VPC range only.

5. Connect the VPN and open the printed URL (`http://<internal-alb-dns-name>`), then continue with
   [Sign in to the UI](#sign-in-to-the-ui) and [Verify](#verify-and-add-a-first-model).

The Client VPN is billed for every hour the endpoint exists (one subnet association) plus each connected client.
When the trial is over, set `create_vpn = false` and run `deploy/deploy.sh`, or remove the whole deployment
([teardown](operations.md#backups-and-teardown)). The demo VPN is not a production access path.

## Private production deployment

Starting from the defaults (`public_mode = false`):

- **Certificate.** Set `certificate_arn` to an ACM certificate in the deployment Region for the name clients will
  use. HTTP on port 80 redirects to HTTPS.
- **DNS (optional).** Set `hosted_zone_id` and `record_name` together to create an alias record; without them,
  clients use the load balancer's DNS name.
- **Client access.** The load balancer admits the VPC CIDR by default. `client_cidrs` replaces that with your
  client ranges (on-premises via VPN or Direct Connect, other VPCs via Transit Gateway);
  `client_security_group_ids` admits security groups.
- **Your own VPC (optional).** Set `vpc_id` and at least two `private_subnet_ids` in different Availability Zones.
  The plan validates them before creating anything: subnets in the VPC, truly private, enough free addresses for
  20 tasks during a rolling deploy plus the load balancer, endpoints and data stores, and DNS support and
  hostnames enabled on the VPC. `create_vpc_endpoints_in_existing_vpc` adds the S3 gateway endpoint (and, with
  `create_interface_endpoints`, the interface endpoints) if the VPC lacks them.
- **Other clients of the data stores (optional).** `extra_data_ingress_security_group_ids` and
  `extra_data_ingress_cidrs` admit non-ECS clients to RDS and Redis. Redis requires TLS and its auth token
  (Secrets Manager, `redis_auth_secret_arn` output): connect with `rediss://`; plain `redis://` connections are
  refused, which looks like a timeout from naive clients.
- **Identity provider.** See [Identity provider](#identity-provider).
- **Licence (optional).** See [operations.md](operations.md#adding-the-litellm-enterprise-licence).

### No outbound internet access

The tasks pull the pinned image from `ghcr.io`, and the identity provider, the LiteLLM licence server and
non-Bedrock providers are internet endpoints. The created VPC has a NAT gateway for this; Bedrock and the other
AWS services can additionally go through interface VPC endpoints (`create_interface_endpoints`, billed per hour
and Availability Zone).

`disable_outbound_network_access = true` creates the VPC without an internet gateway or NAT, with interface
endpoints for Secrets Manager, ECR, CloudWatch Logs, STS and Bedrock runtime, and the S3 gateway endpoint. A
bring-your-own VPC without egress behaves the same way.

> **Air-gapped deployments mirror the image.** Without egress, tasks fail with `CannotPullContainerError`. Copy
> the image into the account's ECR, then set the printed digest-pinned URI as `image_uri`:
>
> ```bash
> deploy/mirror-image.sh --region <region>   # verifies the upstream signature with cosign, prints image_uri = "..."
> ```
>
> The image pull does not use an HTTPS proxy, so `egress_proxy_configured` does not cover it. In a
> bring-your-own VPC, the ECR interface endpoints must exist (`create_vpc_endpoints_in_existing_vpc` with
> `create_interface_endpoints`, or your own). `--registry` pushes to another registry instead of ECR; run
> `deploy/mirror-image.sh --help` for all options.

An identity provider is unreachable in this mode (the plan warns), as are the online licence check and
non-Bedrock providers, unless you route them through an egress proxy (for example
`extra_environment = { HTTPS_PROXY = "http://proxy:3128" }`).

## Public deployment

Set `public_mode = true` and a `certificate_arn`. The load balancer becomes internet-facing in public subnets
(created by the foundation, or `public_subnet_ids` in two Availability Zones for your own VPC) and AWS WAF is
attached with the AWS managed common, known-bad-inputs and IP-reputation rule sets and a rate limit of 2,000
requests per source IP per five minutes (answered with HTTP 429). Body-inspecting rules of the common rule set
only count, because prompts routinely contain HTML, code and URLs. WAF logs go to the `aws-waf-logs-<deployment_name>`
log group with credential headers and cookies redacted. Public mode cannot be combined with
`disable_outbound_network_access` or `allow_insecure_http`.

> **Public mode without an identity provider exposes the admin UI.** The LiteLLM UI, which can create keys,
> change models and read spend for every team, is then reachable from the internet behind only the UI password
> and WAF. The plan warns about it on every run but does not block it. Configure an
> [identity provider](#identity-provider) for public deployments.

## Identity provider

Any OpenID Connect (OIDC) compliant identity provider can protect the UI. Two layers work together:

1. **Load balancer sign-in (`identity_provider`).** The load balancer requires OIDC sign-in before it forwards any
   LiteLLM UI or interactive login path (`/ui`, `/sso/*`, the login and onboarding routes) in both private and
   public mode. API paths are not affected and keep LiteLLM virtual-key authentication. This needs HTTPS, and the
   load balancer must reach the provider's token and user-info endpoints (the stack opens its egress on 443).
2. **LiteLLM SSO (optional).** Behind the load balancer, LiteLLM still asks for its own login. Configuring
   [LiteLLM's SSO](https://docs.litellm.ai/docs/proxy/admin_ui_sso) with the same app registration lets users in
   with the identity provider session they already have, so they sign in once, and maps them to LiteLLM users.
   LiteLLM SSO is free for up to five users; beyond that it requires the
   [LiteLLM Enterprise licence](https://docs.litellm.ai/docs/enterprise).

### Values the load balancer needs

| `identity_provider` field | Value | Microsoft Entra ID example |
| --- | --- | --- |
| `issuer` | The provider's issuer identifier | `https://login.microsoftonline.com/<tenant-id>/v2.0` |
| `authorization_endpoint` | Authorization endpoint | `https://login.microsoftonline.com/<tenant-id>/oauth2/v2.0/authorize` |
| `token_endpoint` | Token endpoint | `https://login.microsoftonline.com/<tenant-id>/oauth2/v2.0/token` |
| `user_info_endpoint` | User-info endpoint | `https://graph.microsoft.com/oidc/userinfo` |
| `client_id` | The application (client) ID | Application (client) ID of the app registration |
| `client_secret_arn` | ARN of a Secrets Manager secret holding the client secret as plain text | A client secret of the app registration |

Your provider's discovery document (`<issuer>/.well-known/openid-configuration`) lists the issuer and endpoints.
The load balancer requests the `openid profile email` scopes. Register this redirect URI with the provider:

```text
https://<gateway-host>/oauth2/idpresponse
```

`<gateway-host>` is `record_name`, or the load balancer DNS name without DNS. The secret value is read by
Terraform and stored in the app's Terraform state, because the load balancer API takes it as a value; the state
bucket is encrypted and private.

### Microsoft Entra ID walkthrough

1. In Microsoft Entra ID, create an app registration (single tenant) with a **Web** redirect URI
   `https://<gateway-host>/oauth2/idpresponse`. If you will use LiteLLM SSO, add
   `https://<gateway-host>/sso/callback` as a second Web redirect URI.
2. Create a client secret under **Certificates & secrets** and store its value in Secrets Manager, for example
   from a file so it stays out of your shell history:

   ```bash
   aws secretsmanager create-secret --name llmgw-entra-client-secret --secret-string file://entra-secret.txt
   ```

3. Set in `deploy/terraform.tfvars`:

   ```hcl
   identity_provider = {
     issuer                 = "https://login.microsoftonline.com/<tenant-id>/v2.0"
     authorization_endpoint = "https://login.microsoftonline.com/<tenant-id>/oauth2/v2.0/authorize"
     token_endpoint         = "https://login.microsoftonline.com/<tenant-id>/oauth2/v2.0/token"
     user_info_endpoint     = "https://graph.microsoft.com/oidc/userinfo"
     client_id              = "<application-client-id>"
     client_secret_arn      = "arn:aws:secretsmanager:<region>:<account-id>:secret:llmgw-entra-client-secret-AbCdEf"
   }
   ```

4. Optional, for single sign-in into LiteLLM itself, pass LiteLLM's Microsoft SSO settings with the same app
   registration. Plain values go in `extra_environment`, the secret through `provider_secret_arns`:

   ```hcl
   extra_environment = {
     MICROSOFT_CLIENT_ID = "<application-client-id>"
     MICROSOFT_TENANT    = "<tenant-id>"
     PROXY_BASE_URL      = "https://<gateway-host>"
   }
   provider_secret_arns = {
     MICROSOFT_CLIENT_SECRET = "arn:aws:secretsmanager:<region>:<account-id>:secret:llmgw-entra-client-secret-AbCdEf"
   }
   ```

   For other providers, use the variables the [LiteLLM SSO documentation](https://docs.litellm.ai/docs/proxy/admin_ui_sso)
   lists for them.

5. Run `deploy/deploy.sh`.

## Sign in to the UI

The UI is at `<gateway-url>/ui`. Without LiteLLM SSO, sign in as `admin` with the generated UI password:

```bash
OUT=deploy/.generated/llmgw-foundation-outputs.tfvars.json   # llmgw = your deployment_name
aws secretsmanager get-secret-value --secret-id "$(jq -r .ui_password_secret_arn "$OUT")" \
  --query SecretString --output text
```

> **UI login is the identity provider or the generated UI password; the master key is not a UI credential.** The
> master key (`master_key_secret_arn`) is the root API credential: use it for administrative API calls such as
> registering models, and give applications LiteLLM virtual keys instead. It is read the same way:
> `--secret-id "$(jq -r .master_key_secret_arn "$OUT")"`.

Managing users, teams, virtual keys and budgets is covered in the
[LiteLLM documentation](https://docs.litellm.ai/docs/proxy/virtual_keys).

## Verify and add a first model

### Smoke test

```bash
deploy/smoke-test.sh --key-secret-arn "$(jq -r .master_key_secret_arn "$OUT")" <gateway-url>
```

It checks liveliness, database connectivity, that a call without a key is refused, an authenticated call, and
that the schema is migrated. The key is fetched at runtime and never printed. Add `--model <model_name>` once a
model exists to run one completion; it checks for HTTP 200 only. `--insecure` skips TLS verification;
`--help` lists every option.

### Add a model

The rendered configuration contains no models. Add them in the UI (**Models**) or through the
[LiteLLM model management API](https://docs.litellm.ai/docs/proxy/model_management); they are stored in the
database. Bedrock models need no credentials: LiteLLM uses the task role. For example, a Bedrock cross-Region
inference profile:

```bash
LITELLM_MASTER_KEY="$(aws secretsmanager get-secret-value --secret-id "$(jq -r .master_key_secret_arn "$OUT")" \
  --query SecretString --output text)"

curl -sS -X POST "<gateway-url>/model/new" \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "model_name": "claude-sonnet",
    "litellm_params": {
      "model": "bedrock/us.anthropic.claude-sonnet-4-20250514-v1:0",
      "aws_region_name": "us-east-1"
    }
  }'
```

Use an inference profile ID your account has access to, and the Region it belongs to. Provider options are in the
[LiteLLM Bedrock documentation](https://docs.litellm.ai/docs/providers/bedrock). By default the task role may
invoke any Bedrock model and inference profile in any Region; `bedrock_model_allowlist`,
`bedrock_region_allowlist` and `cross_account_role_arns` narrow or extend that. Credentials for other providers
reach the tasks through `provider_secret_arns` and are referenced as `os.environ/<NAME>`.

Then call it like any OpenAI-compatible endpoint:

```bash
curl -sS "<gateway-url>/v1/chat/completions" \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model": "claude-sonnet", "messages": [{"role": "user", "content": "What is the capital of Australia?"}]}'
```

> **Test with a natural question.** Echo-style canary prompts ("Say OK", "repeat after me") can come back with
> `finish_reason: "content_filter"` and no content. That is the model's behaviour, not a gateway fault.

> **Models newer than the image show $0 cost.** The tasks use the model price list bundled in the pinned LiteLLM
> image (`LITELLM_LOCAL_MODEL_COST_MAP`, no download at start-up). A model released after that image records
> spend as $0 until you [upgrade the image](operations.md#upgrading-litellm) or set its price in `model_info`
> ([custom pricing](https://docs.litellm.ai/docs/proxy/custom_pricing)).
