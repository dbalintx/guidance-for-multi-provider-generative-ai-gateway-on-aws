"""Offline tests of scripts/render.py and of the manifests against terraform/app/container.tf. No AWS, no cluster."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

import pytest
import yaml

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import render  # noqa: E402

REPO = Path(__file__).resolve().parents[4]
CONTAINER_TF = (REPO / "terraform" / "app" / "container.tf").read_text()
ALB_TF = (REPO / "terraform" / "app" / "alb.tf").read_text()
APP_VARIABLES_TF = (REPO / "terraform" / "app" / "variables.tf").read_text()

DIGEST = "sha256:" + "a" * 64
SHA = "0123456789abcdef" * 4
SECRET = "arn:aws:secretsmanager:ap-southeast-2:111111111111:secret:llmgw-{}-AbCdEf"

TF_OUTPUTS = {  # `terraform output -json` shape
    "namespace": {"value": "litellm"},
    "service_account": {"value": "litellm"},
    "region": {"value": "ap-southeast-2"},
    "config_sha": {"value": SHA},
    "litellm_config_yaml": {"value": "general_settings:\n  proxy_batch_write_at: 60\n"},
}
FOUNDATION = {  # deploy/.generated/<name>-foundation-outputs.tfvars.json shape (flat)
    "redis_endpoint": "master.llmgw-redis.abc123.apse2.cache.amazonaws.com",
    "redis_port": 6379,
    "database_url_secret_arn": SECRET.format("database-url"),
    "master_key_secret_arn": SECRET.format("master-key"),
    "salt_key_secret_arn": SECRET.format("salt-key"),
    "redis_auth_secret_arn": SECRET.format("redis-auth"),
    "ui_password_secret_arn": SECRET.format("ui-password"),
}

# Environment names that differ from container.tf on purpose (deployment.yaml header).
ECS_ONLY_ENV = {"LITELLM_CONFIG_BUCKET_NAME", "LITELLM_CONFIG_BUCKET_OBJECT_KEY"}
EKS_ONLY_ENV = {"AWS_REGION"}


def _tf_map_block(start: str, end: str) -> dict[str, str]:
    """KEY = expression pairs between two markers of container.tf."""
    block = CONTAINER_TF.split(start, 1)[1].split(end, 1)[0]
    pairs = {}
    for line in block.splitlines():
        m = re.match(r"^\s*([A-Z][A-Z0-9_]*)\s*=\s*(.+?)\s*(#.*)?$", line)
        if m:
            pairs[m.group(1)] = m.group(2)
    return pairs


CONTAINER_ENV = _tf_map_block("environment = merge(", "var.extra_environment")
CONTAINER_SECRETS = _tf_map_block("secrets = merge(", "},")


@pytest.fixture(scope="module")
def rendered() -> dict:
    image = render.image_from_container_tf(CONTAINER_TF)
    files = render.render_all(TF_OUTPUTS, FOUNDATION, image)
    docs = {}
    for name, content in files.items():
        assert "${" not in content, name
        docs[name] = list(yaml.safe_load_all(content))
    return docs


def _container(docs: dict, file: str) -> dict:
    (doc,) = docs[file]
    return doc["spec"]["template"]["spec"]["containers"][0]


def _env(container: dict) -> dict:
    return {e["name"]: e.get("value", e.get("valueFrom")) for e in container["env"]}


# --- image ---


def test_image_is_the_one_pinned_in_container_tf():
    image = render.image_from_container_tf(CONTAINER_TF)
    assert re.fullmatch(r"ghcr\.io/berriai/litellm:v[0-9][^@]*@sha256:[0-9a-f]{64}", image)
    assert f'"{image}"' in CONTAINER_TF


@pytest.mark.parametrize(
    "text",
    [
        'image = "ghcr.io/berriai/litellm:v1.0.0"',  # no digest
        'a = "ghcr.io/berriai/litellm:v1@' + DIGEST + '"\nb = "ghcr.io/berriai/litellm:v2@' + DIGEST + '"',
    ],
)
def test_image_needs_exactly_one_pinned_reference(text):
    with pytest.raises(render.RenderError, match="expected one pinned"):
        render.image_from_container_tf(text)


def test_image_override_must_be_pinned_by_digest():
    with pytest.raises(render.RenderError, match="IMAGE"):
        render.render_all(TF_OUTPUTS, FOUNDATION, "111111111111.dkr.ecr.ap-southeast-2.amazonaws.com/litellm:v1")
    files = render.render_all(
        TF_OUTPUTS, FOUNDATION, f"111111111111.dkr.ecr.ap-southeast-2.amazonaws.com/litellm:v1@{DIGEST}"
    )
    assert f"litellm:v1@{DIGEST}" in files["deployment.yaml"]


# --- parity with container.tf ---


def test_environment_names_match_container_tf(rendered):
    for file in ("deployment.yaml", "migrate-job.yaml"):
        env = _env(_container(rendered, file))
        plain = {k for k, v in env.items() if isinstance(v, str)}
        assert plain == (set(CONTAINER_ENV) - ECS_ONLY_ENV) | EKS_ONLY_ENV, file
        secret_refs = {k: v["secretKeyRef"] for k, v in env.items() if not isinstance(v, str)}
        assert set(secret_refs) == set(CONTAINER_SECRETS) == set(render.SECRETS), file
        assert all(ref == {"name": "litellm-secrets", "key": k} for k, ref in secret_refs.items()), file


def test_literal_environment_values_match_container_tf(rendered):
    env = _env(_container(rendered, "deployment.yaml"))
    literals = {k: json.loads(v) for k, v in CONTAINER_ENV.items() if re.fullmatch(r'"[^"]*"', v)}
    assert literals  # the parser found container.tf's literal values
    for name, value in literals.items():
        assert env[name] == value, name
    log_default = re.search(r'variable "log_level" \{.*?default\s*=\s*"([A-Z]+)"', APP_VARIABLES_TF, re.S).group(1)
    assert env["LITELLM_LOG"] == log_default
    idle = int(re.search(r"alb_idle_timeout_seconds\s*=\s*([0-9]+)", ALB_TF).group(1))
    assert env["KEEPALIVE_TIMEOUT"] == str(idle + 5)
    assert env["REDIS_HOST"] == FOUNDATION["redis_endpoint"]
    assert env["REDIS_PORT"] == "6379"
    assert env["LITELLM_CONFIG_SHA"] == SHA
    assert env["AWS_REGION"] == "ap-southeast-2"


def test_migration_job_differs_only_in_schema_updates(rendered):
    deployment = _container(rendered, "deployment.yaml")
    job = _container(rendered, "migrate-job.yaml")
    assert _env(deployment)["DISABLE_SCHEMA_UPDATE"] == "true"
    assert _env(job)["DISABLE_SCHEMA_UPDATE"] == "false"
    assert {**_env(job), "DISABLE_SCHEMA_UPDATE": "true"} == _env(deployment)
    assert job["image"] == deployment["image"] == render.image_from_container_tf(CONTAINER_TF)
    assert job["args"] == [*deployment["args"], "--skip_server_startup"]
    (job_doc,) = rendered["migrate-job.yaml"]
    assert job_doc["spec"]["backoffLimit"] == 0
    assert job_doc["spec"]["template"]["spec"]["restartPolicy"] == "Never"


def test_port_health_check_and_stop_timeout_match_container_tf(rendered):
    port = int(re.search(r"port\s*=\s*([0-9]+)", CONTAINER_TF).group(1))
    path = re.search(r'health_check_path\s*=\s*"([^"]+)"', CONTAINER_TF).group(1)
    stop_timeout = int(re.search(r"stop_timeout\s*=\s*([0-9]+)", CONTAINER_TF).group(1))
    c = _container(rendered, "deployment.yaml")
    assert c["ports"] == [{"name": "http", "containerPort": port}]
    assert c["args"][:2] == ["--port", str(port)]
    for probe in ("startupProbe", "livenessProbe", "readinessProbe"):
        assert c[probe]["httpGet"] == {"path": path, "port": "http"}, probe
    (doc,) = rendered["deployment.yaml"]
    pod = doc["spec"]["template"]["spec"]
    assert pod["terminationGracePeriodSeconds"] == stop_timeout + c["lifecycle"]["preStop"]["sleep"]["seconds"]


def test_config_map_is_content_addressed_and_mounted(rendered):
    (cm,) = rendered[render.CONFIG_MAP_FILE]
    assert cm["metadata"]["name"] == f"litellm-config-{SHA[:16]}"
    assert cm["immutable"] is True
    assert cm["data"]["config.yaml"] == TF_OUTPUTS["litellm_config_yaml"]["value"]
    for file in ("deployment.yaml", "migrate-job.yaml"):
        (doc,) = rendered[file]
        pod = doc["spec"]["template"]["spec"]
        assert pod["volumes"] == [{"name": "config", "configMap": {"name": cm["metadata"]["name"]}}]
        c = pod["containers"][0]
        assert c["volumeMounts"][0]["mountPath"] + "/config.yaml" == c["args"][c["args"].index("--config") + 1]


def test_pods_use_the_pod_identity_service_account(rendered):
    (_, sa) = rendered["namespace.yaml"]
    for file in ("deployment.yaml", "migrate-job.yaml"):
        (doc,) = rendered[file]
        assert doc["spec"]["template"]["spec"]["serviceAccountName"] == sa["metadata"]["name"]
        assert doc["metadata"]["namespace"] == "litellm"


def test_service_selects_only_the_gateway_pods(rendered):
    (svc,) = rendered["service.yaml"]
    (deployment,) = rendered["deployment.yaml"]
    (job,) = rendered["migrate-job.yaml"]
    selector = svc["spec"]["selector"].items()
    assert selector <= deployment["spec"]["template"]["metadata"]["labels"].items()
    assert not selector <= job["spec"]["template"]["metadata"]["labels"].items()
    assert svc["spec"]["type"] == "ClusterIP"


# --- validation ---


@pytest.mark.parametrize(
    ("key", "value"),
    [
        ("redis_endpoint", 'evil"\n  injected: true'),
        ("redis_port", "not-a-port"),
    ],
)
def test_foundation_values_are_validated(key, value):
    with pytest.raises(render.RenderError, match="invalid value"):
        render.render_all(TF_OUTPUTS, {**FOUNDATION, key: value}, f"ghcr.io/berriai/litellm:v1@{DIGEST}")


def test_missing_output_is_reported():
    outputs = {k: v for k, v in TF_OUTPUTS.items() if k != "config_sha"}
    with pytest.raises(render.RenderError, match="config_sha is missing"):
        render.render_all(outputs, FOUNDATION, f"ghcr.io/berriai/litellm:v1@{DIGEST}")


@pytest.mark.parametrize("text", ["a: ${UNKNOWN}", "a: $5"])
def test_unknown_placeholders_fail(text):
    with pytest.raises(render.RenderError):
        render.render_template(text, {"NAMESPACE": "x"})


def test_secret_arns_cover_every_secret_and_are_validated():
    assert render.secret_arns(FOUNDATION) == [
        ("DATABASE_URL", FOUNDATION["database_url_secret_arn"]),
        ("LITELLM_MASTER_KEY", FOUNDATION["master_key_secret_arn"]),
        ("LITELLM_SALT_KEY", FOUNDATION["salt_key_secret_arn"]),
        ("REDIS_PASSWORD", FOUNDATION["redis_auth_secret_arn"]),
        ("UI_PASSWORD", FOUNDATION["ui_password_secret_arn"]),
    ]
    with pytest.raises(render.RenderError, match="invalid secret ARN"):
        render.secret_arns({**FOUNDATION, "salt_key_secret_arn": "arn:aws:s3:::bucket; rm -rf /"})


# --- command line ---


def test_cli_writes_every_manifest(tmp_path, capsys):
    tf = tmp_path / "tf.json"
    tf.write_text(json.dumps(TF_OUTPUTS))
    foundation = tmp_path / "foundation.json"
    foundation.write_text(json.dumps(FOUNDATION))
    out = tmp_path / "out"
    args = ["manifests", "--tf-outputs", str(tf), "--foundation-outputs", str(foundation), "--out-dir", str(out)]
    assert render.main(args) == 0
    assert sorted(p.name for p in out.iterdir()) == sorted([*render.MANIFESTS, render.CONFIG_MAP_FILE])

    assert render.main(["secret-arns", "--foundation-outputs", str(foundation)]) == 0
    lines = capsys.readouterr().out.splitlines()
    assert lines[0] == f"DATABASE_URL {FOUNDATION['database_url_secret_arn']}"
    assert len(lines) == len(render.SECRETS)

    assert render.main([*args[:-1], str(out), "--image", "not-pinned"]) == 1
