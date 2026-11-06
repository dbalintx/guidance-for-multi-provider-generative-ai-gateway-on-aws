# The gateway on Amazon EKS (a starting point)

This example runs the same LiteLLM container on an existing Amazon EKS cluster,
against the gateway's foundation (VPC, RDS PostgreSQL, Redis, Secrets Manager).
It shows that the gateway is not tied to ECS and gives Kubernetes users a small,
readable starting point. **It is a starting point, not the recommended configuration**,
which runs on the ECS Fargate service in `terraform/app`. See
[what ECS has that this lacks](#what-ecs-has-that-this-lacks).

What it is:

- plain Kubernetes manifests (`manifests/`), applied with `kubectl` by one
  script; no Helm chart and no Terraform Kubernetes or Helm provider;
- a small Terraform root module (`terraform/`, AWS provider only) for the pods'
  IAM role, its EKS Pod Identity association, a request-log bucket and the
  rendered LiteLLM config;
- bring-your-own cluster: the example does not create or change a cluster, its
  add-ons, node groups or a load-balancer controller.

```text
 kubectl port-forward            EKS cluster (in the gateway's VPC)
 (or your own ingress) ─────►  ┌─────────────────────────────────────────┐
                               │ namespace litellm                       │
                               │  Service litellm (ClusterIP :4000)      │
                               │   └► Deployment litellm (2 pods) ───────┼──► Amazon Bedrock (Pod Identity role)
                               │  Job litellm-migrate (before a rollout) │
                               │  ConfigMap litellm-config-<sha16>       │──► S3 request logs
                               │  Secret litellm-secrets ◄───────────────┼─── Secrets Manager (copied by deploy.sh)
                               └───────────────┬─────────────────────────┘
                                               └──► RDS PostgreSQL, Redis (foundation; admitted via
                                                    extra_data_ingress_security_group_ids)
```

## How it works

- **Same container settings as ECS.** `manifests/deployment.yaml` is the
  Kubernetes form of the single settings block in `terraform/app/container.tf`:
  image, port, environment, secret names, health-check path and stop timeout.
  The image is not repeated: `scripts/render.py` reads the `tag@digest` pinned
  in `container.tf`, so upgrading the gateway upgrades this example on its next
  deploy. `scripts/tests/test_render.py` fails when the manifests and
  `container.tf` drift apart.
- **Config as a ConfigMap.** Terraform renders LiteLLM's `config.yaml` from the
  gateway's own template (`terraform/app/templates/config-base.yaml.tftpl`), the
  same way `terraform/app/config.tf` does. The ConfigMap is named after the
  config's hash and `LITELLM_CONFIG_SHA` carries the hash, so a config change
  rolls the pods and every ReplicaSet keeps the config it was rolled out with.
  The example does not fetch the ECS deployment's object from the config bucket:
  that would make this example depend on the ECS app being deployed, give the pods
  read access to the bucket and tie them to the ECS deployment's request-log
  bucket. The request logs go to a bucket of this example instead.
- **Secrets.** `scripts/deploy.sh` reads the five generated values (database
  URL, master key, salt key, Redis token, UI password) from Secrets Manager
  and writes them into the Kubernetes Secret `litellm-secrets`, with
  server-side apply (no copy in a last-applied annotation). The scripts do
  not print them or pass them as process arguments.
- **Migration gate.** As on ECS, the pods run with `DISABLE_SCHEMA_UPDATE=true`
  and only a one-off migration (`manifests/migrate-job.yaml`, same image,
  environment and config, `--skip_server_startup`) updates the schema.
  `deploy.sh` deletes the previous Job, runs it once (no retries, 20-minute
  limit) and applies the Deployment only after it completes. LiteLLM reports
  healthy on an unmigrated database, so health checks cannot replace the gate.
- **AWS access: EKS Pod Identity.** The pods get an IAM role equivalent to the
  ECS task role with its default scope: Bedrock inference and guardrails, and
  write-only access to the request-log bucket. Nothing else: the config is a
  ConfigMap and the secrets are a Kubernetes Secret, so no S3 read and no
  Secrets Manager access. The trust policy admits only `pods.eks.amazonaws.com`
  for this account and cluster; the association binds the role to one
  namespace and service account. The example uses Pod Identity rather than IAM
  roles for service accounts (IRSA) because it needs no per-cluster OIDC identity
  provider in IAM, no cluster-specific trust policy and no service-account
  annotation; the binding is an EKS API object that Terraform manages with the
  AWS provider. It needs the EKS Pod Identity Agent (built into EKS Auto Mode,
  an add-on otherwise) and does not work for pods on AWS Fargate.
- **The only change to the gateway** is the foundation's generic
  `extra_data_ingress_security_group_ids` input, which admits the cluster's
  security group to RDS and Redis.

## What ECS has that this lacks

| ECS deployment (`terraform/app`) | This example |
| --- | --- |
| Application Load Balancer with TLS (ACM), access logs and OIDC sign-in in front of the UI paths | A ClusterIP Service only. Exposing it (an ingress controller or load balancer, TLS, sign-in) is left to the cluster's owner. |
| AWS WAF on the internet-facing load balancer (public mode) | None. |
| Rollout in one `terraform apply`: config upload, migration task, then the service; the deployment circuit breaker rolls back a failed rollout | `deploy.sh` gates the Deployment on the migration Job. A failed rollout stops (`maxUnavailable: 0`, the old pods keep serving) but is not rolled back automatically (`kubectl rollout undo`). Changes made with `kubectl` outside `deploy.sh` skip the gate. |
| Secrets stay in Secrets Manager; ECS injects them at task start | Copied into a Kubernetes Secret: readable by anyone who may read Secrets in the namespace; after a rotation, rerun `deploy.sh` (it restarts the pods). |
| CloudWatch log group, alarms, dashboard and SNS notifications (`terraform/modules/observability`) | Logs go to the container's stdout; collecting them, metrics and alarms depend on the cluster's own setup. |
| CPU and memory target-tracking auto scaling, 2 to 20 tasks, sized against the database connection alarm | Two replicas, no HorizontalPodAutoscaler, no PodDisruptionBudget. |
| Drain tuning: 120 s stop timeout aligned with the target deregistration delay; uvicorn keep-alive (605 s) above the 600 s ALB idle timeout | Same 120 s for LiteLLM after SIGTERM, preceded by a 10 s `preStop` pause so the endpoint removal propagates. Any proxy you add needs its own deregistration delay and an idle timeout below 605 s. |
| `config_override_file`, licence and provider secrets, Bedrock model and region allowlists, cross-account roles, `image_uri` | Not wired, except a mirrored image through `IMAGE` (pinned by digest). Models added in the UI or API live in the shared database and work here too. |

## Prerequisites

- A deployed gateway foundation (`deploy/deploy.sh`), whose outputs file
  `deploy/.generated/<deployment_name>-foundation-outputs.tfvars.json` is on
  this machine (or set `FOUNDATION_OUTPUTS`). The ECS app may run alongside:
  both share the database and Redis like more replicas of one gateway.
- An EKS cluster (Kubernetes 1.30 or later, for the `preStop` sleep action) in
  the gateway's region and VPC, with nodes in subnets that reach ghcr.io and
  AWS APIs (for example the foundation's private subnets with the NAT
  gateway), the EKS Pod Identity Agent, and EC2 capacity (EKS Auto Mode or a
  managed node group) for two pods requesting 1 vCPU and 2 GiB each plus the
  migration Job (1 vCPU, 2 GiB).
- `kubectl` with its current context on that cluster
  (`aws eks update-kubeconfig --name <cluster> --region <region>`) and
  permission to create a namespace and the objects in `manifests/`.
- Terraform >= 1.11, the AWS CLI v2, `jq` and `python3`, and AWS credentials
  that may read the gateway's secrets and create the IAM role, the Pod
  Identity association and an S3 bucket.
- The gateway deployment's Terraform state bucket
  (`litellm-gateway-tfstate-<account>-<region>`, or set `TF_STATE_BUCKET`).
  This example's state is stored under `examples/eks/<name>.tfstate`.

### Admit the cluster to the data stores

The pods reach RDS and Redis with the security groups of their node (with the
Amazon VPC CNI). EKS Auto Mode nodes and managed node groups without a custom
launch template use the cluster security group:

```bash
aws eks describe-cluster --name <cluster> --query cluster.resourcesVpcConfig.clusterSecurityGroupId --output text
```

Add it to the gateway's `deploy/terraform.tfvars` and run `deploy/deploy.sh`.
The foundation plan adds two ingress rules (PostgreSQL and Redis); the app plan
has no changes.

```hcl
extra_data_ingress_security_group_ids = ["sg-0123456789abcdef0"]
```

Every node and pod in the cluster security group can then open connections to
the data stores (they still need the credentials). To narrow it, give the
gateway's nodes their own security group, or use security groups for pods, and
admit that group instead. A cluster in another, routed VPC is admitted by CIDR
with `extra_data_ingress_cidrs`.

## Deploy

```bash
cd examples/eks
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# set deployment_name (the gateway's) and cluster_name
export AWS_REGION=<gateway region>
scripts/deploy.sh            # shows the Terraform plan and asks for confirmation
```

`deploy.sh` refuses to run unless kubectl's current context points at
`cluster_name`. It applies the Terraform, renders the manifests, applies the
namespace, service account, ConfigMap and Secret, runs the migration Job and
then rolls out the Deployment and Service. Rerun it after a gateway upgrade, a
config change or a secret rotation; unchanged inputs are a no-op apart from
the migration Job, which runs on every deploy.

Resources created (default `name` `llmgw-eks`, namespace `litellm`):

| Resource | Name |
| --- | --- |
| IAM role and inline policy | `llmgw-eks-pod-role` |
| EKS Pod Identity association | `litellm/litellm` on the cluster |
| S3 bucket for request logs (metadata only, 30 days) | `llmgw-eks-req-logs-<account>-<region>` |
| Namespace, ServiceAccount, Secret, ConfigMap, Job, Deployment, Service | in namespace `litellm` |

## Verify

```bash
kubectl -n litellm get pods              # two litellm pods Running and Ready
kubectl -n litellm port-forward service/litellm 4000:4000
```

In a second terminal, from the repository root:

```bash
deploy/smoke-test.sh --key-secret-arn "$(jq -r .master_key_secret_arn deploy/.generated/<deployment_name>-foundation-outputs.tfvars.json)" \
  http://127.0.0.1:4000
```

Add `--model <name>` for one real completion through Bedrock with the pods'
role (a model registered in the gateway). The admin UI is at
`http://127.0.0.1:4000/ui` (user `admin`, the UI password from the
foundation's `ui_password_secret_arn`). Pod logs:
`kubectl -n litellm logs deployment/litellm`.

## Teardown

```bash
cd examples/eks
AWS_REGION=<gateway region> scripts/teardown.sh
```

It asks for confirmation, deletes the namespace (and everything in it), then
destroys the IAM role, the Pod Identity association and the request-log bucket
with its logs. The cluster and the gateway are not touched; remove the
cluster's security group from `extra_data_ingress_security_group_ids` and
redeploy the gateway afterwards. If the cluster is already gone,
`scripts/teardown.sh --skip-kubernetes` destroys the AWS resources only.

## Tests

Offline, no AWS access and no cluster:

```bash
# The renderer, the manifests against terraform/app/container.tf, and
# deploy.sh / teardown.sh against stub aws, terraform and kubectl commands
python3 -m venv .venv && .venv/bin/pip install -r scripts/requirements-dev.txt
.venv/bin/python -m pytest scripts/tests
(cd scripts && ../.venv/bin/ruff check . && ../.venv/bin/ruff format --check .)
shellcheck -x scripts/*.sh

# Terraform: plans against a mocked AWS provider
terraform -chdir=terraform init -backend=false
terraform -chdir=terraform test
```

With [kubeconform](https://github.com/yannh/kubeconform) on `PATH`, the tests
also validate the rendered manifests against the Kubernetes schemas (it
downloads the schemas on first use).
