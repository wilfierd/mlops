#!/usr/bin/env bash
# Build + push the FastAPI/Embedder app image to the ECR repo owned by the
# persistent stack. The LLM image (vllm-openai) is pulled from upstream by
# the cluster and is NOT built/pushed here.
#
# Inputs (env, all optional):
#   ENV          environments/<env>/persistent — defaults to dev
#   IMAGE_TAG    image tag — defaults to short git SHA (then "dev" if no git)
#   DOCKERFILE   path to Dockerfile — defaults to Dockerfile.app
#   DOCKER_CMD   docker | podman — autodetect
#   IMAGE_PLATFORM  linux/amd64 (always; head + GPU are both x86 in rev3+)
#   ROLL         "true" to kubectl delete pods after push (default: true)
#   NAMESPACE    k8s namespace — defaults to llm-chat
#
# Reads from persistent stack outputs (ECR is owned by persistent).

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV="${ENV:-dev}"
PERSISTENT_DIR="${INFRA_DIR}/environments/${ENV}/persistent"

DOCKER_CMD="${DOCKER_CMD:-docker}"
IMAGE_PLATFORM="${IMAGE_PLATFORM:-linux/amd64}"
NAMESPACE="${NAMESPACE:-llm-chat}"
ROLL="${ROLL:-true}"

if [[ -z "${DOCKERFILE:-}" ]]; then
  DOCKERFILE="${ROOT_DIR}/Dockerfile.app"
fi

if [[ ! -f "${DOCKERFILE}" ]]; then
  echo "Dockerfile not found: ${DOCKERFILE}" >&2
  exit 1
fi

# Image tag: prefer caller-supplied IMAGE_TAG, else short git SHA, else "dev".
if [[ -z "${IMAGE_TAG:-}" ]]; then
  if IMAGE_TAG=$(git -C "${ROOT_DIR}" rev-parse --short HEAD 2>/dev/null); then
    :
  else
    IMAGE_TAG="dev"
  fi
fi

log() { printf '[push] %s\n' "$*"; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing command: $1" >&2
    exit 1
  }
}

main() {
  require_cmd terraform
  require_cmd aws

  if ! command -v "${DOCKER_CMD}" >/dev/null 2>&1; then
    if command -v podman >/dev/null 2>&1; then
      DOCKER_CMD=podman
      log "docker not found, using podman"
    else
      echo "need docker or podman" >&2
      exit 1
    fi
  fi

  if [[ ! -d "${PERSISTENT_DIR}" ]]; then
    echo "persistent stack dir not found: ${PERSISTENT_DIR}" >&2
    echo "did you run 'make persistent-apply' first?" >&2
    exit 1
  fi

  local region repo
  region="$(terraform -chdir="${PERSISTENT_DIR}" output -raw region)"
  repo="$(terraform -chdir="${PERSISTENT_DIR}" output -raw ecr_app_url)"
  local registry="${repo%%/*}"

  log "env=${ENV} region=${region} repo=${repo} tag=${IMAGE_TAG} dockerfile=${DOCKERFILE} platform=${IMAGE_PLATFORM}"

  log "aws ecr login -> ${registry}"
  aws ecr get-login-password --region "${region}" \
    | "${DOCKER_CMD}" login --username AWS --password-stdin "${registry}"

  local platform_args=()
  if [[ -n "${IMAGE_PLATFORM}" ]]; then
    platform_args=(--platform "${IMAGE_PLATFORM}")
  fi

  if [[ "${DOCKER_CMD}" == "docker" ]] && docker buildx version >/dev/null 2>&1; then
    log "buildx build + push ${repo}:${IMAGE_TAG}"
    docker buildx build \
      "${platform_args[@]}" \
      -f "${DOCKERFILE}" \
      -t "${repo}:${IMAGE_TAG}" \
      --push \
      "${ROOT_DIR}"
  else
    log "build ${repo}:${IMAGE_TAG}"
    "${DOCKER_CMD}" build \
      "${platform_args[@]}" \
      -f "${DOCKERFILE}" \
      -t "${repo}:${IMAGE_TAG}" \
      "${ROOT_DIR}"

    log "push ${repo}:${IMAGE_TAG}"
    "${DOCKER_CMD}" push "${repo}:${IMAGE_TAG}"
  fi

  if [[ "${ROLL}" == "true" ]]; then
    log "rolling pods in ${NAMESPACE} so the new image is pulled"
    kubectl -n "${NAMESPACE}" delete pod --all --grace-period=0 --force 2>/dev/null || true
    log "done. monitor: kubectl -n ${NAMESPACE} get pods -w"
  else
    log "done (skipped pod roll because ROLL=${ROLL})"
  fi
}

main "$@"
