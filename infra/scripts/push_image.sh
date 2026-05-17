#!/usr/bin/env bash
# Build + push the chat-app image to the ECR repo created by Terraform.
# Reads outputs from environments/${ENV}/ so it always uses the right account/region/repo.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV="${ENV:-dev}"
ENV_DIR="${INFRA_DIR}/environments/${ENV}"

IMAGE_TAG="${IMAGE_TAG:-}"
PRELOAD_MODEL="${PRELOAD_MODEL:-true}"
INFERENCE_BACKEND="${INFERENCE_BACKEND:-llamacpp}"
GGUF_REPO_ID="${GGUF_REPO_ID:-bartowski/Qwen_Qwen3-0.6B-GGUF}"
GGUF_FILENAME="${GGUF_FILENAME:-Qwen_Qwen3-0.6B-Q4_K_M.gguf}"
DOCKER_CMD="${DOCKER_CMD:-docker}"
IMAGE_PLATFORM="${IMAGE_PLATFORM:-}"

log() { printf '[push] %s\n' "$*"; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "missing command: $1" >&2; exit 1; }
}

main() {
  require_cmd terraform
  require_cmd aws

  if ! command -v "${DOCKER_CMD}" >/dev/null 2>&1; then
    if command -v podman >/dev/null 2>&1; then
      DOCKER_CMD=podman
      log "docker not found, using podman"
    else
      echo "need docker or podman" >&2; exit 1
    fi
  fi

  local region repo model tag
  region="$(terraform -chdir="${ENV_DIR}" output -raw region)"
  repo="$(terraform -chdir="${ENV_DIR}" output -raw ecr_repository_url)"
  model="$(terraform -chdir="${ENV_DIR}" output -raw model_id)"
  tag="${IMAGE_TAG:-$(terraform -chdir="${ENV_DIR}" output -raw image_tag)}"
  local registry="${repo%%/*}"

  log "env=${ENV} region=${region} repo=${repo} tag=${tag} model=${model}"

  log "aws ecr login -> ${registry}"
  aws ecr get-login-password --region "${region}" \
    | "${DOCKER_CMD}" login --username AWS --password-stdin "${registry}"

  if [[ -n "${IMAGE_PLATFORM}" && "${DOCKER_CMD}" == "docker" ]]; then
    log "buildx build ${repo}:${tag} platform=${IMAGE_PLATFORM} (PRELOAD_MODEL=${PRELOAD_MODEL} backend=${INFERENCE_BACKEND})"
    docker buildx build \
      --platform "${IMAGE_PLATFORM}" \
      --build-arg "MODEL_ID=${model}" \
      --build-arg "PRELOAD_MODEL=${PRELOAD_MODEL}" \
      --build-arg "INFERENCE_BACKEND=${INFERENCE_BACKEND}" \
      --build-arg "GGUF_REPO_ID=${GGUF_REPO_ID}" \
      --build-arg "GGUF_FILENAME=${GGUF_FILENAME}" \
      -t "${repo}:${tag}" \
      --push \
      "${ROOT_DIR}"
  else
    log "build ${repo}:${tag} platform=${IMAGE_PLATFORM:-native} (PRELOAD_MODEL=${PRELOAD_MODEL} backend=${INFERENCE_BACKEND})"
    local platform_args=()
    if [[ -n "${IMAGE_PLATFORM}" ]]; then
      platform_args=(--platform "${IMAGE_PLATFORM}")
    fi
    "${DOCKER_CMD}" build \
      "${platform_args[@]}" \
      --build-arg "MODEL_ID=${model}" \
      --build-arg "PRELOAD_MODEL=${PRELOAD_MODEL}" \
      --build-arg "INFERENCE_BACKEND=${INFERENCE_BACKEND}" \
      --build-arg "GGUF_REPO_ID=${GGUF_REPO_ID}" \
      --build-arg "GGUF_FILENAME=${GGUF_FILENAME}" \
      -t "${repo}:${tag}" \
      "${ROOT_DIR}"

    log "push ${repo}:${tag}"
    "${DOCKER_CMD}" push "${repo}:${tag}"
  fi

  log "rolling pods to pick up new image"
  kubectl -n llm-chat delete pod --all --grace-period=0 --force 2>/dev/null || true

  log "done. monitor: kubectl -n llm-chat get pods -w"
}

main "$@"
