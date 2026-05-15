#!/usr/bin/env bash
# One-shot: dam bao minikube + cluster + KubeRay, sau do build/load image va apply RayService.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

MINIKUBE_DRIVER="${MINIKUBE_DRIVER:-}"
MINIKUBE_CPUS="${MINIKUBE_CPUS:-6}"
MINIKUBE_MEMORY="${MINIKUBE_MEMORY:-8192}"
MINIKUBE_PROFILE="${MINIKUBE_PROFILE:-llm-chat}"

log() { printf '[minikube] %s\n' "$*"; }

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'missing command: %s\n' "$1" >&2
    exit 1
  fi
}

# Phat hien docker shim (vd podman-docker). Tra ve 0 neu la docker that.
is_real_docker() {
  command -v docker >/dev/null 2>&1 || return 1
  local ver
  ver="$(docker --version 2>/dev/null || true)"
  [[ -n "${ver}" && "${ver,,}" != *podman* ]]
}

# Chon driver:
# - MINIKUBE_DRIVER override -> dung luon.
# - Co docker that -> docker.
# - Co podman -> podman (uu tien hon docker shim).
# - Else: empty.
auto_driver() {
  if [[ -n "${MINIKUBE_DRIVER}" ]]; then
    printf '%s' "${MINIKUBE_DRIVER}"
    return
  fi
  if is_real_docker; then
    printf 'docker'
    return
  fi
  if command -v podman >/dev/null 2>&1; then
    printf 'podman'
    return
  fi
  printf ''
}

main() {
  require_cmd kubectl
  require_cmd helm

  local driver
  driver="$(auto_driver)"
  if [[ -z "${driver}" ]]; then
    echo "khong tim thay docker hoac podman de lam driver cho minikube" >&2
    exit 1
  fi

  # Cai minikube neu thieu (delegate cho setup_minikube.sh).
  if ! command -v minikube >/dev/null 2>&1; then
    log "minikube chua co, goi setup_minikube.sh"
    MINIKUBE_DRIVER="${driver}" \
      MINIKUBE_PROFILE="${MINIKUBE_PROFILE}" \
      MINIKUBE_CPUS="${MINIKUBE_CPUS}" \
      MINIKUBE_MEMORY="${MINIKUBE_MEMORY}" \
      "${ROOT_DIR}/scripts/setup_minikube.sh"
  else
    if minikube -p "${MINIKUBE_PROFILE}" status >/dev/null 2>&1; then
      log "profile ${MINIKUBE_PROFILE} dang chay"
    else
      log "start profile ${MINIKUBE_PROFILE} driver=${driver}"
      local extra=()
      if [[ "${driver}" == "podman" ]]; then
        # podman rootless + cri-o tren Fedora hay loi `image not known` khi
        # cri-o resolve image kindnetd. Dung containerd on dinh hon.
        extra+=(--container-runtime="${MINIKUBE_RUNTIME:-containerd}")
        if ! podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null | grep -qi false; then
          extra+=(--rootless)
        fi
      fi
      minikube start \
        -p "${MINIKUBE_PROFILE}" \
        --driver="${driver}" \
        --cpus="${MINIKUBE_CPUS}" \
        --memory="${MINIKUBE_MEMORY}" \
        "${extra[@]}"
    fi
  fi

  # Nang pids-limit cua container minikube (idempotent). Mac dinh podman rootless
  # cap 2048 -> Ray head fork hang chuc dashboard subprocess se hit pthread_create.
  log "raise pids-limit on container '${MINIKUBE_PROFILE}'"
  "${driver}" update --pids-limit=-1 "${MINIKUBE_PROFILE}" >/dev/null 2>&1 || true

  kubectl config use-context "${MINIKUBE_PROFILE}" >/dev/null

  LOAD_IMAGE=minikube \
    MINIKUBE_PROFILE="${MINIKUBE_PROFILE}" \
    DOCKER_CMD="${DOCKER_CMD:-${driver}}" \
    PRELOAD_MODEL="${PRELOAD_MODEL:-true}" \
    "${ROOT_DIR}/scripts/deploy.sh"
}

main "$@"
