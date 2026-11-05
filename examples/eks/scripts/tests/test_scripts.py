"""Offline tests of deploy.sh and teardown.sh with stub aws, terraform and kubectl on PATH.

The stubs log every call; kubectl stores what it receives on stdin. The tests run
under /bin/bash (3.2 on macOS) in a copy of the example. No AWS, no cluster.
"""

from __future__ import annotations

import base64
import json
import os
import shutil
import subprocess
from pathlib import Path

import pytest

EXAMPLE = Path(__file__).resolve().parents[2]
REPO = EXAMPLE.parents[1]
SECRET = "arn:aws:secretsmanager:ap-southeast-2:111111111111:secret:llmgw-{}-AbCdEf"
SECRET_VALUE = "s3cr3t-value-of-{}"  # what the aws stub returns for a secret
ENDPOINT = "https://ABC123.gr7.ap-southeast-2.eks.amazonaws.com"

FOUNDATION = {
    "vpc_cidr": "10.0.0.0/16",
    "redis_endpoint": "master.llmgw-redis.abc123.apse2.cache.amazonaws.com",
    "redis_port": 6379,
    "database_url_secret_arn": SECRET.format("database-url"),
    "master_key_secret_arn": SECRET.format("master-key"),
    "salt_key_secret_arn": SECRET.format("salt-key"),
    "redis_auth_secret_arn": SECRET.format("redis-auth"),
    "ui_password_secret_arn": SECRET.format("ui-password"),
}
TF_OUTPUTS = {
    "namespace": {"value": "litellm"},
    "service_account": {"value": "litellm"},
    "region": {"value": "ap-southeast-2"},
    "config_sha": {"value": "ab" * 32},
    "litellm_config_yaml": {"value": "general_settings: {}\n"},
}

AWS_STUB = r"""#!/bin/bash
printf 'aws %s\n' "$*" >>"$STUB_LOG"
case "$1 $2" in
  "sts get-caller-identity") echo 111111111111 ;;
  "s3api head-bucket") exit 0 ;;
  "eks describe-cluster") echo "$STUB_ENDPOINT" ;;
  "secretsmanager get-secret-value")
    arn="$4"; name="${arn##*secret:llmgw-}"; printf 's3cr3t-value-of-%s\n' "${name%-AbCdEf}" ;;
  *) echo "aws stub: unexpected $*" >&2; exit 1 ;;
esac
"""

TERRAFORM_STUB = r"""#!/bin/bash
printf 'terraform %s\n' "$*" >>"$STUB_LOG"
for a in "$@"; do
  case "$a" in
    console) printf '"llmgw-eks"\n"llmgw"\n"trial"\n'; exit 0 ;;
    -json) cat "$STUB_TF_OUTPUTS"; exit 0 ;;
    -raw) echo litellm; exit 0 ;;
  esac
done
exit 0
"""

KUBECTL_STUB = r"""#!/bin/bash
printf 'kubectl %s\n' "$*" >>"$STUB_LOG"
args=" $* "
case "$args" in
  *" config current-context "*) echo trial-context ;;
  *" config view "*) printf '%s' "$STUB_SERVER" ;;
  *" -f - "*) n=$(ls "$STUB_DIR"/stdin-* 2>/dev/null | wc -l | tr -d ' '); cat >"$STUB_DIR/stdin-$n" ;;
  *" get job "*) printf '%s' "$STUB_JOB_CONDITIONS" ;;
  *" get secret "*) f="$STUB_DIR/secret-version"; [ -f "$f" ] && cat "$f" ;;
  *" get deployment "*) [ -f "$STUB_DIR/deployment" ] && echo 1 ;;
  *" apply "*)
    case "$args" in *deployment.yaml*) touch "$STUB_DIR/deployment" ;; esac ;;
esac
exit 0
"""


@pytest.fixture
def env(tmp_path):
    """A copy of the example and container.tf, the stubs, and the environment to run the scripts."""
    root = tmp_path / "repo"
    shutil.copytree(EXAMPLE, root / "examples" / "eks", ignore=shutil.ignore_patterns(".terraform", "__pycache__"))
    (root / "terraform" / "app").mkdir(parents=True)
    shutil.copy(REPO / "terraform" / "app" / "container.tf", root / "terraform" / "app")
    (root / "examples" / "eks" / "terraform" / "terraform.tfvars").write_text(
        'deployment_name = "llmgw"\ncluster_name = "trial"\n'
    )
    stub_dir = tmp_path / "stub"
    bin_dir = stub_dir / "bin"
    bin_dir.mkdir(parents=True)
    for name, body in (("aws", AWS_STUB), ("terraform", TERRAFORM_STUB), ("kubectl", KUBECTL_STUB)):
        (bin_dir / name).write_text(body)
        (bin_dir / name).chmod(0o755)
    foundation = tmp_path / "foundation.json"
    foundation.write_text(json.dumps(FOUNDATION))
    tf_outputs = tmp_path / "tf-outputs.json"
    tf_outputs.write_text(json.dumps(TF_OUTPUTS))
    log = stub_dir / "calls.log"
    log.touch()
    return {
        "root": root,
        "stub_dir": stub_dir,
        "log": log,
        "vars": {
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "HOME": str(tmp_path),
            "TMPDIR": str(tmp_path),
            "AWS_REGION": "ap-southeast-2",
            "FOUNDATION_OUTPUTS": str(foundation),
            "STUB_LOG": str(log),
            "STUB_DIR": str(stub_dir),
            "STUB_TF_OUTPUTS": str(tf_outputs),
            "STUB_ENDPOINT": ENDPOINT,
            "STUB_SERVER": ENDPOINT.lower() + "/",
            "STUB_JOB_CONDITIONS": "Complete ",
        },
    }


def run(env, script, *args, **overrides):
    return subprocess.run(
        ["/bin/bash", str(env["root"] / "examples" / "eks" / "scripts" / script), *args],
        env={**env["vars"], **overrides},
        capture_output=True,
        text=True,
        timeout=60,
    )


def calls(env, tool):
    return [line for line in env["log"].read_text().splitlines() if line.startswith(tool + " ")]


def test_deploy_applies_in_order_with_the_migration_gate(env):
    result = run(env, "deploy.sh", "--auto-approve")
    assert result.returncode == 0, result.stderr
    kubectl = calls(env, "kubectl")
    order = [
        next(i for i, c in enumerate(kubectl) if marker in c)
        for marker in ("namespace.yaml", "configmap.json", " -f -", "delete job", "migrate-job.yaml", "deployment.yaml")
    ]
    assert order == sorted(order)
    assert all("--context trial-context" in c for c in kubectl if not c.startswith("kubectl config"))
    assert all("--server-side" in c for c in kubectl if " apply " in c)
    assert "rollout status deployment/litellm" in "\n".join(kubectl)
    assert "port-forward service/litellm 4000:4000" in result.stdout
    assert any("terraform apply" in c and "-auto-approve" in c for c in calls(env, "terraform"))


def test_secret_values_reach_kubectl_on_stdin_only(env):
    result = run(env, "deploy.sh", "--auto-approve")
    assert result.returncode == 0, result.stderr
    secret = (env["stub_dir"] / "stdin-0").read_text()
    assert "kind: Secret" in secret and "namespace: litellm" in secret
    data = dict(line.strip().split(": ", 1) for line in secret.split("\ndata:\n", 1)[1].splitlines() if line.strip())
    expected = {
        "DATABASE_URL": "database-url",
        "LITELLM_MASTER_KEY": "master-key",
        "LITELLM_SALT_KEY": "salt-key",
        "REDIS_PASSWORD": "redis-auth",
        "UI_PASSWORD": "ui-password",
    }
    assert {k: base64.b64decode(v).decode() for k, v in data.items()} == {
        k: SECRET_VALUE.format(v) for k, v in expected.items()
    }
    everything_visible = env["log"].read_text() + result.stdout + result.stderr
    assert "s3cr3t" not in everything_visible  # never in argv, never printed


def test_failed_migration_leaves_the_deployment_unchanged(env):
    result = run(env, "deploy.sh", "--auto-approve", STUB_JOB_CONDITIONS="Failed ")
    assert result.returncode == 1
    assert "Migration failed; the Deployment was not changed" in result.stderr
    assert not any("deployment.yaml" in c for c in calls(env, "kubectl"))


def test_secret_rotation_restarts_unchanged_pods(env):
    (env["stub_dir"] / "deployment").touch()  # the Deployment exists and its template does not change
    version = env["stub_dir"] / "secret-version"
    version.write_text("1")
    # The kubectl stub reports a new resourceVersion once the Secret was applied.
    kubectl = env["stub_dir"] / "bin" / "kubectl"
    kubectl.write_text(
        kubectl.read_text().replace(
            'cat >"$STUB_DIR/stdin-$n" ;;', 'cat >"$STUB_DIR/stdin-$n"; echo 2 >"$STUB_DIR/secret-version" ;;'
        )
    )
    result = run(env, "deploy.sh", "--auto-approve")
    assert result.returncode == 0, result.stderr
    assert any("rollout restart deployment/litellm" in c for c in calls(env, "kubectl"))


def test_deploy_refuses_another_cluster_context(env):
    result = run(env, "deploy.sh", "--auto-approve", STUB_SERVER="https://other.example.com")
    assert result.returncode == 1
    assert "is not cluster trial" in result.stderr
    assert not any(" apply " in c for c in calls(env, "kubectl") + calls(env, "terraform"))


def test_deploy_needs_the_foundation_outputs(env, tmp_path):
    result = run(env, "deploy.sh", "--auto-approve", FOUNDATION_OUTPUTS=str(tmp_path / "missing.json"))
    assert result.returncode == 1
    assert "run deploy/deploy.sh for the gateway first" in result.stderr


def test_image_override_must_be_pinned(env):
    result = run(env, "deploy.sh", "--auto-approve", IMAGE="registry.example.com/litellm:latest")
    assert result.returncode == 1
    assert "invalid value for IMAGE" in result.stderr
    assert not any(" apply " in c for c in calls(env, "kubectl"))


def test_teardown_deletes_the_namespace_then_the_aws_resources(env):
    result = run(env, "teardown.sh", "--auto-approve")
    assert result.returncode == 0, result.stderr
    log = env["log"].read_text()
    assert log.index("delete namespace litellm --ignore-not-found --wait=true") < log.index(" destroy ")


def test_teardown_without_kubernetes_or_foundation(env, tmp_path):
    result = run(env, "teardown.sh", "--auto-approve", "--skip-kubernetes", FOUNDATION_OUTPUTS=str(tmp_path / "gone"))
    assert result.returncode == 0, result.stderr
    assert not calls(env, "kubectl")
    assert any(" destroy " in c for c in calls(env, "terraform"))
