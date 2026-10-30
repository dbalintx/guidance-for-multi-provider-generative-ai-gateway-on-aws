#!/bin/bash
# Optional helper: copy the upstream LiteLLM image into a registry you control
# (by default this account's ECR), so the gateway tasks can pull it without
# reaching ghcr.io. Nothing in Terraform or deploy.sh calls this script; use the
# printed URI as the app's image_uri variable. Run with --help for details.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER_TF="${SCRIPT_DIR}/../terraform/app/container.tf"
SOURCE_REPO="ghcr.io/berriai/litellm"
# BerriAI signs its releases with this key; the URL is pinned to the commit
# that introduced it, so a later change to the file cannot swap the key.
COSIGN_KEY="https://raw.githubusercontent.com/BerriAI/litellm/0112e53046018d726492c814b3644b7d376029d0/cosign.pub"

usage() {
  cat <<'EOF'
Usage: deploy/mirror-image.sh [options]

Copies the official LiteLLM container image (ghcr.io/berriai/litellm) into a
registry you control and prints the resulting image URI. The gateway does not
need this: by default its tasks pull the pinned upstream image from ghcr.io.
Use it when the tasks cannot reach ghcr.io (no internet egress, or a policy
that only allows images from your own registry), then set in
deploy/terraform.tfvars:

  image_uri = "<the URI this script prints>"

Options:
  --version <tag>      Image tag to copy, e.g. v1.106.6. Default: the tag
                       pinned in terraform/app/container.tf.
  --platform <os/arch> Platform to copy. Default linux/arm64, which matches the
                       app's default architecture = "arm"; use linux/amd64
                       with architecture = "x86".
  --registry <prefix>  Push to this registry/namespace instead of ECR, e.g.
                       registry.example.com/platform. You must already be
                       logged in to it (docker login). No AWS calls are made.
  --repository <name>  Repository name. Default: litellm.
  --region <region>    ECR region. Default: AWS_REGION, then the AWS CLI's
                       configured region. Ignored with --registry.
  --dry-run            Pull and verify the upstream image only; push nothing
                       and make no AWS calls.
  -h, --help           Show this help.

With the default ECR target the script creates the repository if it is
missing (immutable tags, scan on push), logs Docker in to ECR and pushes.
The AWS identity needs ecr:DescribeRepositories, ecr:CreateRepository,
ecr:GetAuthorizationToken, ecr:BatchCheckLayerAvailability,
ecr:InitiateLayerUpload, ecr:UploadLayerPart, ecr:CompleteLayerUpload,
ecr:PutImage, ecr:DescribeImages and sts:GetCallerIdentity.

If cosign is installed, the upstream image signature is verified before
anything is pushed; a failed verification stops the script.

The printed URI is pinned by digest (repository@sha256:...), so the tasks run
exactly the image that was verified and pushed.

Requires: docker (with a running daemon); the AWS CLI for the ECR target;
cosign is optional but recommended.

Exit codes: 0 success, 1 failure, 2 usage error.
EOF
}

die() { echo "Error: $*" >&2; exit 1; }
usage_error() { echo "Error: $*" >&2; echo "Run '$0 --help' for usage." >&2; exit 2; }

VERSION="" PLATFORM="linux/arm64" REGISTRY="" REPOSITORY="litellm" REGION="" DRY_RUN=false
while [ $# -gt 0 ]; do
  case "$1" in
    --version | --platform | --registry | --repository | --region)
      [ $# -ge 2 ] && [ -n "$2" ] || usage_error "$1 needs a value."
      case "$1" in
        --version) VERSION="$2" ;;
        --platform) PLATFORM="$2" ;;
        --registry) REGISTRY="${2%/}" ;;
        --repository) REPOSITORY="$2" ;;
        --region) REGION="$2" ;;
      esac
      shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h | --help) usage; exit 0 ;;
    *) usage_error "unknown option: $1" ;;
  esac
done

if [ -z "$VERSION" ]; then
  [ -f "$CONTAINER_TF" ] || usage_error "--version is required (terraform/app/container.tf not found)."
  VERSION="$(sed -n 's|.*"ghcr\.io/berriai/litellm:\([^"]*\)".*|\1|p' "$CONTAINER_TF" | head -n 1)"
  [ -n "$VERSION" ] || usage_error "--version is required (no pinned tag found in terraform/app/container.tf)."
fi
[[ "$VERSION" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || usage_error "--version must be an image tag, e.g. v1.106.6."
[[ "$PLATFORM" =~ ^linux/(arm64|amd64)$ ]] || usage_error "--platform must be linux/arm64 or linux/amd64."
[[ "$REPOSITORY" =~ ^[a-z0-9]+([._/-][a-z0-9]+)*$ ]] || usage_error "--repository must be a lowercase repository name."

command -v docker >/dev/null 2>&1 || die "docker is required."
docker info >/dev/null 2>&1 || die "the Docker daemon is not running."

SOURCE="${SOURCE_REPO}:${VERSION}"
echo "Pulling ${SOURCE} (${PLATFORM})"
docker pull --quiet --platform "$PLATFORM" "$SOURCE" >/dev/null || die "could not pull ${SOURCE}."
SOURCE_DIGEST="$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$SOURCE" |
  sed -n "s|^${SOURCE_REPO}@||p" | head -n 1)"
[ -n "$SOURCE_DIGEST" ] || die "could not read the upstream digest of ${SOURCE}."
echo "Upstream digest: ${SOURCE_DIGEST}"

if command -v cosign >/dev/null 2>&1; then
  cosign verify --key "$COSIGN_KEY" "${SOURCE_REPO}@${SOURCE_DIGEST}" >/dev/null ||
    die "cosign could not verify the signature of ${SOURCE_REPO}@${SOURCE_DIGEST}; nothing was pushed."
  echo "Signature verified with cosign."
else
  echo "cosign not installed: the upstream signature was NOT verified."
fi

if [ "$DRY_RUN" = true ]; then
  echo "Dry run: nothing pushed."
  exit 0
fi

if [ -z "$REGISTRY" ]; then
  command -v aws >/dev/null 2>&1 || die "the AWS CLI is required for the ECR target (or pass --registry)."
  REGION="${REGION:-${AWS_REGION:-$(aws configure get region || true)}}"
  [ -n "$REGION" ] || die "no region: pass --region, set AWS_REGION or configure a default region."
  ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
  REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

  if ! aws ecr describe-repositories --region "$REGION" --repository-names "$REPOSITORY" >/dev/null 2>&1; then
    aws ecr create-repository --region "$REGION" --repository-name "$REPOSITORY" \
      --image-tag-mutability IMMUTABLE --image-scanning-configuration scanOnPush=true >/dev/null
    echo "Created ECR repository ${REPOSITORY} (immutable tags, scan on push)."
  fi
  # The registry password goes through a pipe, never through argv or the terminal.
  aws ecr get-login-password --region "$REGION" |
    docker login --username AWS --password-stdin "$REGISTRY" >/dev/null
fi

TARGET_REPO="${REGISTRY}/${REPOSITORY}"
TARGET="${TARGET_REPO}:${VERSION}"
docker tag "$SOURCE" "$TARGET"
echo "Pushing ${TARGET}"
if ! docker push --quiet "$TARGET" >/dev/null; then
  # ECR tags are immutable: the push fails when the tag already exists. Accept
  # that only when ECR confirms the tag is there, and say which image it is.
  if [ -n "${ACCOUNT_ID:-}" ] && STORED_DIGEST="$(aws ecr describe-images --region "$REGION" \
    --repository-name "$REPOSITORY" --image-ids imageTag="$VERSION" \
    --query 'imageDetails[0].imageDigest' --output text 2>/dev/null)" && [[ "$STORED_DIGEST" == sha256:* ]]; then
    echo "Tag ${VERSION} already exists in ${TARGET_REPO}; using the stored image."
    echo "Check that it is the image you expect before deploying it."
    echo ""
    echo "image_uri = \"${TARGET_REPO}@${STORED_DIGEST}\""
    exit 0
  fi
  die "could not push ${TARGET}."
fi

DIGEST="$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$TARGET" |
  sed -n "s|^${TARGET_REPO}@||p" | head -n 1)"
[ -n "$DIGEST" ] || die "pushed ${TARGET} but could not read its digest."

echo ""
echo "Mirrored ${SOURCE} to ${TARGET_REPO}. Pass it to the app in deploy/terraform.tfvars:"
echo ""
echo "image_uri = \"${TARGET_REPO}@${DIGEST}\""
