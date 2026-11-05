# Load test

Measures the gateway's capacity and behaviour under load without model cost: a
fake OpenAI-compatible upstream streams synthetic tokens with a configurable
latency, and a [locust](https://locust.io) driver loads the gateway with chat
completions, streaming and not. Both run inside the gateway VPC (a VPN or a
laptop link limits and distorts the results).

What a run tells you:

- **Per-task capacity**: concurrent streams and requests per second at which
  time to first token (TTFT), total time or errors start to climb.
- **CPU and memory per task** at each load level, and whether CPU
  target tracking scales the service out before latency degrades.
- **Memory over time** under steady load (leaks show as per-task growth that is
  not reclaimed).
- **Errors**: HTTP status classes, ALB 5xx/502s, streams cut short.

```
locust driver (EC2, SSM) ──> gateway ALB ──> LiteLLM tasks ──> internal NLB ──> fake upstream (ECS)
```

| Path | Content |
|---|---|
| `fake_upstream/server.py` | Fake upstream: `/v1/chat/completions`, SSE streaming, latency profile from the environment or a `/p/<ttft_ms>/<itl_ms>/<tokens>/v1` path prefix |
| `locust/locustfile.py` | Scenario: closed-loop users (one request in flight each), stream/non-stream mix, cache-busting prompts, optional step profile, per-request JSONL log |
| `terraform/` | Fake upstream (Fargate + internal NLB), driver (EC2, no inbound), artifacts bucket, key secret |
| `scripts/gateway.sh` | Registers the fake models and a virtual key on the gateway; removes them |
| `scripts/driver.sh` | Starts, checks, fetches and stops runs on the driver through SSM |
| `analysis/summarize.py` | Client-side tables per step or per minute |
| `analysis/collect_metrics.py` | Server-side tables: per-task CPU/memory, service averages, ALB 5xx, scaling activities |

## Prerequisites

- A deployed gateway, its admin (master) key in Secrets Manager, and a machine
  that reaches the gateway URL for the admin API (`scripts/gateway.sh`).
- Private subnets with outbound internet access (NAT): the fake upstream
  installs `aiohttp` from PyPI, the driver installs locust.
- Terraform >= 1.11, the AWS CLI, `jq`, `curl`; Python 3.11+ with
  `pip install -r requirements.txt` for the analysis scripts and tests.

The fake upstream is unauthenticated: it serves synthetic text only, and its
security groups admit only the gateway tasks and the driver. The driver has no
inbound rules. Results contain no prompts or keys.

## Deploy

```bash
cd loadtest/terraform
cat > loadtest.auto.tfvars <<'EOF'
vpc_id                    = "vpc-..."
subnet_ids                = ["subnet-...", "subnet-..."]   # private, with NAT
gateway_security_group_id = "sg-..."                       # <deployment_name>-service-sg
gateway_url               = "http://internal-<alb>.<region>.elb.amazonaws.com"   # or https://<gateway host>
EOF
terraform init && terraform apply
```

State is local by default; `providers.tf` shows how to keep it in the gateway's
state bucket under a `loadtest/` key. The latency profile (`fake_profile`)
defaults to 500 ms TTFT, 25 ms between tokens, 100-400 tokens per response and
one token per SSE chunk (about 7 s per stream; one token per chunk is the
gateway's worst case, as it handles every chunk).

Register the models and the key (the key goes straight into the driver's secret):

```bash
export GATEWAY_URL=http://internal-<alb>...   MASTER_KEY_SECRET_ID=<deployment>-master-key...
scripts/gateway.sh setup
```

This adds `<prefix>-fake` (the profile above) and `<prefix>-fake-instant` (no
delays, 20 tokens: measures the gateway's own overhead).

## Run

```bash
# 1. Control: the driver straight at the fake upstream. It must hold far more
#    load than the gateway will, or the fake upstream is the bottleneck.
FAKE=$(terraform -chdir=terraform output -raw fake_api_base)
scripts/driver.sh run control GATEWAY_URL=${FAKE%/v1} MODEL=fake STEPS=50:120,200:120,500:180

# 2. Saturation: step the concurrency up, hold each step long enough for
#    1-minute metrics (>= 4 min).
scripts/driver.sh run steps STEPS=10:300,20:300,40:300,60:300,80:300,120:300

# 3. Soak: steady load below saturation for >= 60 min (memory over time).
scripts/driver.sh run soak USERS=40 SPAWN_RATE=2 RUN_TIME=75m

scripts/driver.sh status steps      # running | done (exit status)
scripts/driver.sh fetch steps       # -> loadtest/results/steps/
scripts/driver.sh stop              # stops every running locust
```

Scenario settings (`KEY=VALUE`): `STEPS` or `USERS`/`SPAWN_RATE`/`RUN_TIME`,
`MODEL`, `STREAM_RATIO` (default 0.8), `PROMPT_CHARS` (2000), `MAX_TOKENS`,
`WAIT_MIN`/`WAIT_MAX` (think time, 1-3 s), `PROCESSES` (locust processes,
default one per vCPU). Every prompt starts with a UUID: the gateway's response
cache would otherwise answer repeated prompts from Redis.

The user count is the number of requests in flight: each user sends one request,
waits for the whole response (or stream), thinks, and repeats.

## Read the results

```bash
python analysis/summarize.py results/steps            # one row per step
python analysis/summarize.py results/soak --minutes   # one row per minute
python analysis/collect_metrics.py --cluster <deployment>-cluster --service <deployment>-litellm \
  --alb-arn-suffix "$(terraform -chdir=../terraform/app output -raw alb_arn_suffix)" \
  --target-group-arn-suffix "$(terraform -chdir=../terraform/app output -raw target_group_arn_suffix)" \
  --start <run start, ISO UTC> --end <run end> --out results/steps/server
```

(`run.json` holds the start time; the summary prints each step's start.)

- **Saturation point**: the step at which TTFT p95 or the error share climbs
  while req/s stops growing. Compare the task CPU % (`tasks.csv`) at that step
  with the CPU target-tracking value: if the service never reaches the target
  before latency climbs, CPU scaling does not protect latency.
- **Memory**: `tasks.csv` memory per task over the soak. Growth that continues
  at constant load, and is not returned after the load stops, is a leak.
- **Errors**: `error classes` (HTTP status, or the exception for streams cut
  short) and the ALB counts in `service.csv` (`elb_502` without matching
  `target_5xx` points at connection reuse between the ALB and the tasks).
- `overhead p50/p95 ms` is LiteLLM's own `x-litellm-overhead-duration-ms`:
  time spent in the gateway outside the upstream call.
- Check the fake upstream's CPU in Container Insights (`<prefix>-cluster`): it
  must stay well below its limit. Locust warns in `locust.log` when the driver's
  CPU is the limit.
- Runs differ by 10-20 % with identical settings; repeat a step before reading a
  smaller difference into it.

Load against a shared gateway also writes the request logs (S3) and spend
records (database) of every request; the auto scaling policies act on it as on
real traffic.

## Teardown

```bash
scripts/gateway.sh teardown            # models and keys named <prefix>-*
terraform -chdir=terraform destroy
```

## Tests

```bash
pip install -r requirements.txt
ruff check . && pytest                 # fake upstream, stream parsing, summaries
terraform -chdir=terraform test        # mocked provider, no AWS access
```
