# Deployment

This page takes you from an empty AWS account to a verified gateway. Every input is listed in
[configuration.md](configuration.md).

- [Choose a deployment](#choose-a-deployment)
- [Prerequisites](#prerequisites)
- [Trial deployment](#trial-deployment)
- [Recommended private deployment](#recommended-private-deployment)
- [Public deployment](#public-deployment)
- [Identity provider](#identity-provider)
- [Deploy](#deploy)
- [Sign in to the UI](#sign-in-to-the-ui)
- [Verify and add a first model](#verify-and-add-a-first-model)
- [Teardown](#teardown)

## Choose a deployment

### Deployment types

1. **[Trial](#trial-deployment): for testing only.** A private gateway on plain HTTP, reached through a demo AWS
   Client VPN, without a LiteLLM licence or identity provider. Use it to explore LiteLLM; do not use it for real
   workloads or send real credentials through it.
2. **[Recommended private](#recommended-private-deployment).** The recommended configuration: an internal load
   balancer with HTTPS, a DNS name, an identity provider in front of the UI and a LiteLLM Enterprise licence,
   reached from your own network.
3. **[Public](#public-deployment).** An internet-facing load balancer with HTTPS and AWS WAF, for clients that
   cannot reach your network. Use it with an identity provider.

| | Trial | Recommended (private) | Public |
| --- | --- | --- | --- |
| Load balancer | Internal | Internal | Internet-facing, AWS WAF |
| Protocol | Plain HTTP | HTTPS (your ACM certificate) | HTTPS (your ACM certificate) |
| Client access | Demo Client VPN | Your VPN, Direct Connect or Transit Gateway | Internet |
| Identity provider | Not available (needs HTTPS) | Recommended | Strongly recommended |
| LiteLLM licence | No | Recommended | Recommended |

### Optional features

- **DNS name.** `hosted_zone_id` and `record_name` create an Amazon Route 53 alias record for the load balancer.
  Without them, clients use the load balancer's own DNS name.
- **Certificate.** `certificate_arn` is an AWS Certificate Manager (ACM) certificate for the name clients use; the
  load balancer serves HTTPS with it and redirects HTTP to HTTPS. Required unless `allow_insecure_http = true`
  (trial only).
- **Private or public mode.** `public_mode = false` (the default) keeps the load balancer internal; `true` makes
  it internet-facing and attaches AWS WAF.
- **LiteLLM licence.** `litellm_license_secret_arn` enables the
  [LiteLLM Enterprise features](https://docs.litellm.ai/docs/enterprise). Without it LiteLLM runs its
  open-source feature set (MIT License).
- **Identity provider.** `identity_provider` makes the load balancer require OpenID Connect (OIDC) sign-in before
  it serves the LiteLLM UI. See [Identity provider](#identity-provider).

All deployment types use the same scripts and one input file. Copy the example and edit it as described for your
deployment type:

```bash
cp deploy/terraform.tfvars.example deploy/terraform.tfvars
```

`deployment_name` (default `llmgw` in the example) prefixes every resource; use a different name for each
deployment in an account. Secrets never go in this file: secret inputs are Secrets Manager ARNs.

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

### Service quotas

Check these default quotas before the first deployment: Elastic IP addresses (one for the NAT gateway), VPCs per
Region, Application Load Balancers per Region, and Fargate On-Demand vCPUs (enough for the maximum task count in
the [architecture](../README.md#architecture)).

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

## Trial deployment

> **For testing only.** The trial serves plain HTTP, is reachable only through a demo Client VPN that shares one
> client certificate, and runs without a licence or identity provider. `allow_insecure_http` cannot be combined
> with public mode or an identity provider. Move to the
> [recommended private deployment](#recommended-private-deployment) before real use.

**Prerequisites.** The [common prerequisites](#prerequisites) and two VPN certificates in ACM. Create them with
the `deployment_name` from your tfvars:

```bash
deploy/setup-vpn.sh certs --name llmgw --region <region>
```

The script creates a local CA, a server certificate and one shared client certificate (RSA 2048; Client VPN
accepts only RSA 1024 or 2048) under `~/.llm-gateway-vpn/<name>/`, imports them into ACM and prints the
certificate ARNs. The private keys are kept on your machine and in ACM, not in Terraform state.

**Settings** in `deploy/terraform.tfvars`:

```hcl
deployment_name     = "llmgw"
allow_insecure_http = true
deletion_protection = false # optional: lets deploy/undeploy.sh remove the trial in one step

create_vpn                      = true
vpn_server_certificate_arn      = "arn:aws:acm:..." # printed by setup-vpn.sh certs
vpn_client_root_certificate_arn = "arn:aws:acm:..." # printed by setup-vpn.sh certs
```

VPN clients get addresses from `vpn_client_cidr` (default `10.250.0.0/22`), which must not overlap the VPC. The
VPN is split-tunnel and authorised for the VPC range only. Then [deploy](#deploy) and
[connect the VPN](#connect-the-trial-vpn).

When the trial is over, set `create_vpn = false` and run `deploy/deploy.sh`, or remove the whole deployment
([teardown](#teardown)). The demo VPN is for testing only; use Direct Connect, Transit Gateway or your own VPN
for regular access.

## Recommended private deployment

The recommended deployment: the load balancer stays internal (`public_mode = false`, the default) and clients
reach it over your own network.

**Prerequisites.** Besides the [common prerequisites](#prerequisites):

- an ACM certificate in the deployment Region for the name clients will use;
- optionally, a Route 53 hosted zone for that name;
- a network path from your clients to the VPC (VPN, AWS Direct Connect or AWS Transit Gateway);
- an OIDC identity provider application (see [Identity provider](#identity-provider));
- a LiteLLM Enterprise licence key, stored as a plain-text Secrets Manager secret, for example
  `aws secretsmanager create-secret --name llmgw-litellm-license --secret-string file://license.txt`. LiteLLM
  checks the licence online, so the tasks need outbound internet access.

**Settings** in `deploy/terraform.tfvars`:

```hcl
deployment_name = "llmgw"

certificate_arn = "arn:aws:acm:<region>:<account-id>:certificate/..."
hosted_zone_id  = "Z0123456789ABCDEFGHIJ" # optional, set both or neither
record_name     = "llm.example.com"       # optional, set both or neither

client_cidrs              = ["10.20.0.0/16"] # optional: your client ranges; default is the VPC CIDR only
client_security_group_ids = []               # optional: client security groups

identity_provider = { ... } # see Identity provider

litellm_license_secret_arn = "arn:aws:secretsmanager:<region>:<account-id>:secret:llmgw-litellm-license-AbCdEf"

alarm_email = "ops@example.com" # optional: alarm notifications (confirm the subscription email)
```

HTTP on port 80 redirects to HTTPS. `client_cidrs` replaces the default VPC CIDR with your client ranges
(on-premises via VPN or Direct Connect, other VPCs via Transit Gateway); `client_security_group_ids` admits
security groups.

### Your own VPC

Set `vpc_id` and at least two `private_subnet_ids` in different Availability Zones. The plan validates them before
creating anything: subnets in the VPC, truly private, enough free addresses for 20 tasks during a rolling deploy
plus the load balancer, endpoints and data stores, and DNS support and hostnames enabled on the VPC.
`create_vpc_endpoints_in_existing_vpc` adds the S3 gateway endpoint (and, with `create_interface_endpoints`, the
interface endpoints) if the VPC lacks them.

### Other clients of the data stores

`extra_data_ingress_security_group_ids` and `extra_data_ingress_cidrs` admit non-ECS clients to RDS and Redis.
Redis requires TLS and its auth token (Secrets Manager, `redis_auth_secret_arn` output): connect with `rediss://`;
plain `redis://` connections are refused, which looks like a timeout from naive clients.

### No outbound internet access

The tasks pull the pinned image from `ghcr.io`, and the identity provider, the LiteLLM licence server and
non-Bedrock providers are internet endpoints. The created VPC has a NAT gateway for this; Bedrock and the other
AWS services can additionally go through interface VPC endpoints (`create_interface_endpoints`).

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

The load balancer becomes internet-facing in public subnets (created by the foundation, or `public_subnet_ids` in
two Availability Zones for your own VPC) and AWS WAF is attached with the AWS managed common, known-bad-inputs and
IP-reputation rule sets and a rate limit of 2,000 requests per source IP per five minutes (answered with HTTP
429). Body-inspecting rules of the common rule set only count, because prompts routinely contain HTML, code and
URLs. WAF logs go to the `aws-waf-logs-<deployment_name>` log group with credential headers and cookies redacted.

**Prerequisites.** As for the [recommended private deployment](#recommended-private-deployment), except the
network path: clients come from the internet.

**Settings** in `deploy/terraform.tfvars`: the recommended private deployment's settings without `client_cidrs`
and `client_security_group_ids`, plus:

```hcl
public_mode = true
```

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
   [LiteLLM's SSO](https://docs.litellm.ai/docs/proxy/admin_ui_sso) with the same application lets users in with
   the identity provider session they already have, so they sign in once, and maps them to LiteLLM users. Pass
   its settings as plain values in `extra_environment` and secrets through `provider_secret_arns`. LiteLLM SSO is
   free for up to five users; beyond that it requires the licence.

Register this redirect URI (Amazon Cognito: allowed callback URL; Microsoft Entra ID: **Web** redirect URI) with
the provider:

```text
https://<gateway-host>/oauth2/idpresponse
```

`<gateway-host>` is `record_name`, or the load balancer DNS name without DNS. The load balancer requests the
`openid profile email` scopes. The provider's discovery document (`<issuer>/.well-known/openid-configuration`)
lists the issuer and endpoints.

| `identity_provider` field | Value | Amazon Cognito example | Microsoft Entra ID example |
| --- | --- | --- | --- |
| `issuer` | Issuer identifier | `https://cognito-idp.<region>.amazonaws.com/<user-pool-id>` | `https://login.microsoftonline.com/<tenant-id>/v2.0` |
| `authorization_endpoint` | Authorization endpoint | `https://<domain>.auth.<region>.amazoncognito.com/oauth2/authorize` | `https://login.microsoftonline.com/<tenant-id>/oauth2/v2.0/authorize` |
| `token_endpoint` | Token endpoint | `https://<domain>.auth.<region>.amazoncognito.com/oauth2/token` | `https://login.microsoftonline.com/<tenant-id>/oauth2/v2.0/token` |
| `user_info_endpoint` | User-info endpoint | `https://<domain>.auth.<region>.amazoncognito.com/oauth2/userInfo` | `https://graph.microsoft.com/oidc/userinfo` |
| `client_id` | Client ID of the application | App client ID (an app client with a client secret) | Application (client) ID of the app registration |
| `client_secret_arn` | ARN of a Secrets Manager secret holding the client secret as plain text | Secret holding the app client secret | Secret holding a client secret of the app registration |

For example:

```hcl
identity_provider = {
  issuer                 = "https://login.microsoftonline.com/<tenant-id>/v2.0"
  authorization_endpoint = "https://login.microsoftonline.com/<tenant-id>/oauth2/v2.0/authorize"
  token_endpoint         = "https://login.microsoftonline.com/<tenant-id>/oauth2/v2.0/token"
  user_info_endpoint     = "https://graph.microsoft.com/oidc/userinfo"
  client_id              = "<application-client-id>"
  client_secret_arn      = "arn:aws:secretsmanager:<region>:<account-id>:secret:llmgw-idp-client-secret-AbCdEf"
}
```

Create the secret from a file so the value stays out of your shell history:
`aws secretsmanager create-secret --name llmgw-idp-client-secret --secret-string file://client-secret.txt`. The
secret value is read by Terraform and stored in the app's Terraform state, because the load balancer API takes it
as a value; the state bucket is encrypted and private.

## Deploy

### Run the deployment

```bash
deploy/deploy.sh
```

It plans and applies the foundation, then the app, asking for confirmation before each apply (`--auto-approve`
skips the prompts), and prints the gateway URL at the end. The first run generates the master key, the salt key,
the UI password, the Redis auth token and the database password in Secrets Manager.

> **The salt key must never change.** LiteLLM uses it to encrypt the provider credentials stored in its database;
> a new salt key would make them unreadable.

### Connect the trial VPN

Trial deployments only. Wait until the Client VPN endpoint is `available` (several minutes after the apply
returns), then write the VPN profile and import it into an OpenVPN-compatible client (AWS VPN Client, Tunnelblick
or `openvpn`; the script detects which one is installed and prints the import steps):

```bash
deploy/setup-vpn.sh profile --name llmgw --region <region>
```

The `.ovpn` file contains the shared client private key; do not share or commit it. Connect the VPN and open the
printed URL (`http://<internal-alb-dns-name>`).

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
that the schema is migrated. The script fetches the key at runtime and does not print it. Add `--model <model_name>` once a
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
    "model_name": "claude-opus-5-5",
    "litellm_params": {
      "model": "bedrock/au.anthropic.claude-opus-5-5",
      "aws_region_name": "ap-southeast-2"
    }
  }'
```

Use an inference profile ID your account has access to, and the Region it belongs to. List the profiles available
in a Region with `aws bedrock list-inference-profiles --region <region> --query 'inferenceProfileSummaries[].inferenceProfileId'`.
Provider options are in the
[LiteLLM Bedrock documentation](https://docs.litellm.ai/docs/providers/bedrock). By default the task role may
invoke any Bedrock model and inference profile in any Region; `bedrock_model_allowlist`,
`bedrock_region_allowlist` and `cross_account_role_arns` narrow or extend that. Credentials for other providers
reach the tasks through `provider_secret_arns` and are referenced as `os.environ/<NAME>`.

Models, keys, configuration files and other content that you create and upload are "Your Content" as defined in
the [AWS Customer Agreement](https://aws.amazon.com/agreement/). AWS does not claim ownership of it.

Then call it like any OpenAI-compatible endpoint:

```bash
curl -sS "<gateway-url>/v1/chat/completions" \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model": "claude-opus-5-5", "messages": [{"role": "user", "content": "What is the capital of Australia?"}]}'
```

> **Test with a natural question.** Echo-style canary prompts ("Say OK", "repeat after me") can come back with
> `finish_reason: "content_filter"` and no content. That is the model's behaviour, not a gateway fault.

Models newer than the image show $0 cost: the tasks use the model price list bundled in the pinned LiteLLM image
(`LITELLM_LOCAL_MODEL_COST_MAP`, no download at start-up). A model released after that image records spend as $0
until a newer image is deployed or you set its price in `model_info`
([custom pricing](https://docs.litellm.ai/docs/proxy/custom_pricing)).

## Teardown

Set `deletion_protection = false` in `deploy/terraform.tfvars` and run `deploy/deploy.sh`, then run
`deploy/undeploy.sh`. It destroys the app, then the foundation, asking for confirmation before each destroy. The
database still leaves a final snapshot (unless `destroy_data_without_snapshot = true`), and the Terraform state
bucket is kept.
