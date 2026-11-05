#!/usr/bin/env python3
"""Render the example's Kubernetes manifests. Standard library only; no secrets.

  render.py manifests --tf-outputs <file> --foundation-outputs <file> --out-dir <dir> [--image <ref>]
  render.py secret-arns --foundation-outputs <file>

`manifests` fills the ${...} placeholders of ../manifests/*.yaml and writes the
ConfigMap holding the rendered LiteLLM config (named after its hash, so every
ReplicaSet keeps the config it was rolled out with). The image is the one
pinned in terraform/app/container.tf unless --image overrides it (a mirrored
copy). Every value is validated before it is written into a manifest.

`secret-arns` prints "<ENV_NAME> <secret ARN>" lines for scripts/deploy.sh,
which reads the values from Secrets Manager itself.

Inputs are `terraform output -json` of examples/eks/terraform and the gateway's
foundation outputs file written by deploy/deploy.sh.
"""

from __future__ import annotations

import argparse
import json
import re
import string
import sys
from pathlib import Path

EXAMPLE_DIR = Path(__file__).resolve().parents[1]
MANIFESTS_DIR = EXAMPLE_DIR / "manifests"
CONTAINER_TF = EXAMPLE_DIR.parents[1] / "terraform" / "app" / "container.tf"

# Manifests in the order scripts/deploy.sh applies them.
MANIFESTS = ("namespace.yaml", "migrate-job.yaml", "deployment.yaml", "service.yaml")
CONFIG_MAP_FILE = "configmap.json"

# Environment name -> foundation output holding the Secrets Manager ARN; the
# names are container.tf's `secrets` keys.
SECRETS = {
    "DATABASE_URL": "database_url_secret_arn",
    "LITELLM_MASTER_KEY": "master_key_secret_arn",
    "LITELLM_SALT_KEY": "salt_key_secret_arn",
    "REDIS_PASSWORD": "redis_auth_secret_arn",
    "UI_PASSWORD": "ui_password_secret_arn",
}

_DNS_LABEL = r"[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?"
VALIDATORS = {
    "NAMESPACE": _DNS_LABEL,
    "SERVICE_ACCOUNT": _DNS_LABEL,
    "CONFIG_MAP": r"litellm-config-[0-9a-f]{16}",
    "CONFIG_SHA": r"[0-9a-f]{64}",
    "AWS_REGION": r"[a-z]{2}(-[a-z]+)+-[0-9]",
    "REDIS_HOST": r"[A-Za-z0-9.-]{1,253}",
    "REDIS_PORT": r"[1-9][0-9]{0,4}",
    # registry/repository[:tag]@sha256:<digest> — always pinned by digest.
    "IMAGE": r"[a-z0-9.-]+(:[0-9]+)?/[a-z0-9._/-]+(:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127})?@sha256:[0-9a-f]{64}",
}
SECRET_ARN = r"arn:aws[a-z-]*:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:[A-Za-z0-9/_+=.@-]+"

_PINNED_IMAGE = re.compile(r'"(ghcr\.io/berriai/litellm:[^"@\s]+@sha256:[0-9a-f]{64})"')


class RenderError(Exception):
    """Invalid or missing input; the message says which."""


def image_from_container_tf(text: str) -> str:
    """The upstream image (tag@digest) pinned in container.tf: exactly one."""
    found = _PINNED_IMAGE.findall(text)
    if len(found) != 1:
        raise RenderError(
            f"expected one pinned ghcr.io/berriai/litellm:<tag>@sha256:<digest> in container.tf, found {len(found)}"
        )
    return found[0]


def validate(values: dict[str, str]) -> dict[str, str]:
    for name, pattern in VALIDATORS.items():
        value = values.get(name)
        if value is None:
            raise RenderError(f"missing value for {name}")
        if not re.fullmatch(pattern, value):
            raise RenderError(f"invalid value for {name}: {value!r}")
    return values


def render_template(text: str, values: dict[str, str]) -> str:
    """Fill ${NAME} placeholders; any unknown placeholder or stray '$' is an error."""
    try:
        return string.Template(text).substitute(values)
    except KeyError as e:
        raise RenderError(f"no value for placeholder {e}") from None
    except ValueError as e:
        raise RenderError(f"invalid placeholder: {e}") from None


def _output(outputs: dict, name: str):
    """A value from `terraform output -json` ({name: {value: ...}}) or a flat file ({name: value})."""
    if name not in outputs:
        raise RenderError(f"output {name} is missing")
    value = outputs[name]
    return value["value"] if isinstance(value, dict) and "value" in value else value


def values_from(tf_outputs: dict, foundation: dict, image: str) -> dict[str, str]:
    sha = str(_output(tf_outputs, "config_sha"))
    return validate(
        {
            "NAMESPACE": str(_output(tf_outputs, "namespace")),
            "SERVICE_ACCOUNT": str(_output(tf_outputs, "service_account")),
            "AWS_REGION": str(_output(tf_outputs, "region")),
            "CONFIG_SHA": sha,
            "CONFIG_MAP": f"litellm-config-{sha[:16]}",
            "IMAGE": image,
            "REDIS_HOST": str(_output(foundation, "redis_endpoint")),
            "REDIS_PORT": str(_output(foundation, "redis_port")),
        }
    )


def config_map(values: dict[str, str], config_yaml: str) -> dict:
    return {
        "apiVersion": "v1",
        "kind": "ConfigMap",
        "metadata": {
            "name": values["CONFIG_MAP"],
            "namespace": values["NAMESPACE"],
            "labels": {"app.kubernetes.io/name": "litellm", "app.kubernetes.io/component": "config"},
        },
        "immutable": True,  # content-addressed: a config change is a new ConfigMap
        "data": {"config.yaml": config_yaml},
    }


def render_all(tf_outputs: dict, foundation: dict, image: str, manifests_dir: Path = MANIFESTS_DIR) -> dict[str, str]:
    """File name -> rendered content."""
    values = values_from(tf_outputs, foundation, image)
    config_yaml = str(_output(tf_outputs, "litellm_config_yaml"))
    rendered = {name: render_template((manifests_dir / name).read_text(), values) for name in MANIFESTS}
    rendered[CONFIG_MAP_FILE] = json.dumps(config_map(values, config_yaml), indent=2) + "\n"
    return rendered


def secret_arns(foundation: dict) -> list[tuple[str, str]]:
    pairs = []
    for env_name, output in SECRETS.items():
        arn = str(_output(foundation, output))
        if not re.fullmatch(SECRET_ARN, arn):
            raise RenderError(f"invalid secret ARN in {output}: {arn!r}")
        pairs.append((env_name, arn))
    return pairs


def _load_json(path: str) -> dict:
    try:
        return json.loads(Path(path).read_text())
    except (OSError, json.JSONDecodeError) as e:
        raise RenderError(f"cannot read {path}: {e}") from None


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    m = sub.add_parser("manifests", help="render the manifests into --out-dir")
    m.add_argument("--tf-outputs", required=True)
    m.add_argument("--foundation-outputs", required=True)
    m.add_argument("--out-dir", required=True)
    m.add_argument("--image", help="override the image pinned in container.tf (must be pinned by digest)")
    m.add_argument("--container-tf", default=str(CONTAINER_TF))
    s = sub.add_parser("secret-arns", help="print '<ENV_NAME> <ARN>' lines")
    s.add_argument("--foundation-outputs", required=True)
    args = parser.parse_args(argv)

    try:
        foundation = _load_json(args.foundation_outputs)
        if args.command == "secret-arns":
            for env_name, arn in secret_arns(foundation):
                print(env_name, arn)
            return 0
        image = args.image or image_from_container_tf(Path(args.container_tf).read_text())
        rendered = render_all(_load_json(args.tf_outputs), foundation, image)
        out = Path(args.out_dir)
        out.mkdir(parents=True, exist_ok=True)
        for name, content in rendered.items():
            (out / name).write_text(content)
        print(f"Rendered {len(rendered)} manifests (image {image})", file=sys.stderr)
        return 0
    except RenderError as e:
        print(f"render.py: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
