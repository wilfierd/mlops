#!/usr/bin/env bash
# Cai dat (neu can) va khoi tao minikube + KubeRay operator de chay RayService cuc bo.
# Mac dinh dung driver podman vi may nay co podman; co the dat MINIKUBE_DRIVER=docker.
set -euo pipefail

PROFILE="${MINIKUBE_PROFILE:-llm-chat}"
DRIVER="${MINIKUBE_DRIVER:-podman}"
CPUS="${MINIKUBE_CPUS:-6}"
MEMORY="${MINIKUBE_MEMORY:-8192}"
DISK="${MINIKUBE_DISK:-20g}"
K8S_VERSION="${K8S_VERSION:-v1.30.0}"
KUBERAY_NAMESPACE="${KUBERAY_NAMESPACE:-kuberay-system}"

log() { printf '[setup] %s\n' "$*"; }

install_minikube() {
  if command -v minikube >/dev/null 2>&1; then
    log "minikube da co: $(minikube version --short 2>/dev/null || minikube version | head -1)"
    return
  fi

  log "minikube chua co, tien hanh tai ban moi nhat"
  local tmp
  tmp="$(mktemp -d)"
  local arch
  arch="$(uname -m)"
  case "${arch}" in
    x86_64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) printf 'unsupported arch: %s\n' "${arch}" >&2; exit 1 ;;
  esac

  curl -fsSL -o "${tmp}/minikube" \
    "https://storage.googleapis.com/minikube/releases/latest/minikube-linux-${arch}"
  chmod +x "${tmp}/minikube"

  if [[ -w /usr/local/bin ]]; then
    mv "${tmp}/minikube" /usr/local/bin/minikube
  else
    log "can sudo de cai vao /usr/local/bin"
    sudo install -m 0755 "${tmp}/minikube" /usr/local/bin/minikube
  fi
  rm -rf "${tmp}"
  log "minikube installed: $(minikube version --short 2>/dev/null || minikube version | head -1)"
}

ensure_driver() {
  case "${DRIVER}" in
    podman)
      command -v podman >/dev/null 2>&1 || { echo "podman missing"; exit 1; }
      ;;
    docker)
      command -v docker >/dev/null 2>&1 || { echo "docker missing"; exit 1; }
      ;;
    *)
      log "driver ${DRIVER}: assume da cai san"
      ;;
  esac
}

start_cluster() {
  if minikube -p "${PROFILE}" status >/dev/null 2>&1; then
    log "cluster ${PROFILE} da chay"
    return
  fi

  log "start minikube profile=${PROFILE} driver=${DRIVER} cpus=${CPUS} mem=${MEMORY}MB"
  local extra=()
  if [[ "${DRIVER}" == "podman" ]]; then
    extra+=(--container-runtime="${MINIKUBE_RUNTIME:-containerd}")
    if ! podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null | grep -qi false; then
      extra+=(--rootless)
    fi
  fi
  minikube start \
    -p "${PROFILE}" \
    --driver="${DRIVER}" \
    --cpus="${CPUS}" \
    --memory="${MEMORY}" \
    --disk-size="${DISK}" \
    --kubernetes-version="${K8S_VERSION}" \
    "${extra[@]}"

  # Mac dinh pids_limit cua podman rootless container la 2048 -> qua thap cho Ray head
  # (Ray dashboard fork hang chuc subprocess). Nang len khong gioi han.
  if [[ "${DRIVER}" == "podman" ]] || [[ "${DRIVER}" == "docker" ]]; then
    log "raise pids-limit on minikube container '${PROFILE}'"
    "${DRIVER}" update --pids-limit=-1 "${PROFILE}" >/dev/null 2>&1 || true
  fi

  minikube -p "${PROFILE}" addons enable metrics-server >/dev/null 2>&1 || true
}

install_kuberay() {
  if helm status -n "${KUBERAY_NAMESPACE}" kuberay-operator >/dev/null 2>&1; then
    log "KubeRay operator da cai"
    return
  fi

  log "cai KubeRay operator"
  helm repo add kuberay https://ray-project.github.io/kuberay-helm/ >/dev/null
  helm repo update >/dev/null
  helm upgrade --install kuberay-operator kuberay/kuberay-operator \
    --namespace "${KUBERAY_NAMESPACE}" \
    --create-namespace
  kubectl -n "${KUBERAY_NAMESPACE}" rollout status deploy/kuberay-operator --timeout=180s
}

print_next() {
  cat <<EOF

Done.

Kubectl context:
  $(kubectl config current-context 2>/dev/null || echo "(unset)")

Tiep theo: build image + deploy ung dung.
  MINIKUBE_PROFILE=${PROFILE} ./scripts/deploy.sh
EOF
}

main() {
  install_minikube
  ensure_driver
  start_cluster
  install_kuberay
  print_next
}

main "$@"
