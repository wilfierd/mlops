#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="${ROOT_DIR}/k8s/rayservice.yaml"

IMAGE="${IMAGE:-llm-chat-ray:0.1.0}"
MODEL_ID="${MODEL_ID:-HuggingFaceTB/SmolLM2-135M-Instruct}"
NAMESPACE="${NAMESPACE:-llm-chat}"
KUBERAY_NAMESPACE="${KUBERAY_NAMESPACE:-kuberay-system}"
INSTALL_KUBERAY="${INSTALL_KUBERAY:-auto}"
BUILD_IMAGE="${BUILD_IMAGE:-true}"
PUSH_IMAGE="${PUSH_IMAGE:-false}"
PRELOAD_MODEL="${PRELOAD_MODEL:-false}"
LOAD_IMAGE="${LOAD_IMAGE:-auto}"
PORT_FORWARD="${PORT_FORWARD:-false}"
MINIKUBE_PROFILE="${MINIKUBE_PROFILE:-llm-chat}"
DOCKER_CMD="${DOCKER_CMD:-}"

DEFAULT_IMAGE="llm-chat-ray:0.1.0"
DEFAULT_MODEL_ID="HuggingFaceTB/SmolLM2-135M-Instruct"

log() {
  printf '[deploy] %s\n' "$*"
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'missing command: %s\n' "$1" >&2
    exit 1
  fi
}

escape_sed_replacement() {
  # Su dung delimiter '#' nen chi can escape '#' va '&'.
  printf '%s' "$1" | sed -e 's/[#&]/\\&/g'
}

detect_image_loader() {
  if [[ "${LOAD_IMAGE}" != "auto" ]]; then
    printf '%s' "${LOAD_IMAGE}"
    return
  fi

  local context
  context="$(kubectl config current-context 2>/dev/null || true)"

  if command -v kind >/dev/null 2>&1 && [[ "${context}" == kind-* ]]; then
    printf 'kind'
    return
  fi

  if command -v minikube >/dev/null 2>&1 \
    && minikube -p "${MINIKUBE_PROFILE}" status >/dev/null 2>&1 \
    && [[ "${context}" == "${MINIKUBE_PROFILE}" || "${context}" == minikube* ]]; then
    printf 'minikube'
    return
  fi

  printf 'none'
}

detect_docker_cmd() {
  if [[ -n "${DOCKER_CMD}" ]]; then
    printf '%s' "${DOCKER_CMD}"
    return
  fi
  if command -v docker >/dev/null 2>&1; then
    printf 'docker'
    return
  fi
  if command -v podman >/dev/null 2>&1; then
    printf 'podman'
    return
  fi
  printf ''
}

install_kuberay() {
  if [[ "${INSTALL_KUBERAY}" == "false" ]]; then
    log "skip KubeRay install"
    return
  fi

  if [[ "${INSTALL_KUBERAY}" == "auto" ]] && kubectl get crd rayservices.ray.io >/dev/null 2>&1; then
    log "KubeRay CRD already exists; skip operator install"
    return
  fi

  if ! command -v helm >/dev/null 2>&1; then
    cat >&2 <<EOF
missing command: helm

KubeRay operator is required before applying RayService.

Options:
  1. Install Helm, then run:
     ./scripts/deploy.sh

  2. If KubeRay is already installed in the cluster, run:
     INSTALL_KUBERAY=false ./scripts/deploy.sh

  3. Install KubeRay manually, then rerun this script.
EOF
    exit 1
  fi

  log "install or upgrade KubeRay operator"
  helm repo add kuberay https://ray-project.github.io/kuberay-helm/ >/dev/null
  helm repo update >/dev/null
  helm upgrade --install kuberay-operator kuberay/kuberay-operator \
    --namespace "${KUBERAY_NAMESPACE}" \
    --create-namespace
}

build_image() {
  if [[ "${BUILD_IMAGE}" != "true" ]]; then
    log "skip image build"
    return
  fi

  local cmd
  cmd="$(detect_docker_cmd)"
  if [[ -z "${cmd}" ]]; then
    printf 'no container build tool found (docker/podman)\n' >&2
    exit 1
  fi

  log "build image ${IMAGE} via ${cmd}"
  "${cmd}" build \
    --build-arg "MODEL_ID=${MODEL_ID}" \
    --build-arg "PRELOAD_MODEL=${PRELOAD_MODEL}" \
    -t "${IMAGE}" \
    "${ROOT_DIR}"

  # Podman luu image khong qualifier voi prefix `localhost/`. Chuan hoa IMAGE
  # de cac buoc sau (save/load + manifest) tham chieu dung ten thuc te.
  if [[ "${cmd}" == "podman" ]] && [[ "${IMAGE}" != */* ]]; then
    IMAGE="localhost/${IMAGE}"
    log "podman normalized image name -> ${IMAGE}"
  fi
}

# Sau khi load image vao minikube, them tag docker.io/library/<name> de
# cri-o/containerd resolve unqualified name tu manifest.
tag_image_in_minikube() {
  local short="$1"
  if [[ -z "$short" ]]; then return; fi
  local bare="${short#localhost/}"
  podman exec "${MINIKUBE_PROFILE}" sh -c "command -v ctr >/dev/null 2>&1 && ctr -n k8s.io images tag ${short} docker.io/library/${bare} 2>/dev/null || true" 2>/dev/null || true
}

publish_or_load_image() {
  local loader cmd
  loader="$(detect_image_loader)"
  cmd="$(detect_docker_cmd)"

  if [[ "${PUSH_IMAGE}" == "true" ]]; then
    if [[ -z "${cmd}" ]]; then
      printf 'no container tool found (docker/podman)\n' >&2
      exit 1
    fi
    log "push image ${IMAGE} via ${cmd}"
    "${cmd}" push "${IMAGE}"
    return
  fi

  case "${loader}" in
    kind)
      require_cmd kind
      log "load image into kind cluster"
      kind load docker-image "${IMAGE}"
      ;;
    minikube)
      require_cmd minikube
      log "load image into minikube profile=${MINIKUBE_PROFILE}"
      if [[ "${cmd}" == "podman" ]]; then
        # `minikube image load NAME` voi podman driver hay loi vi minikube
        # tim image trong docker. Xuat sang tar roi load la cach chac chan.
        local tar
        tar="$(mktemp --suffix=.tar)"
        log "podman save ${IMAGE} -> ${tar}"
        podman save -o "${tar}" "${IMAGE}"
        minikube -p "${MINIKUBE_PROFILE}" image load "${tar}"
        rm -f "${tar}"
      else
        minikube -p "${MINIKUBE_PROFILE}" image load "${IMAGE}"
      fi
      tag_image_in_minikube "${IMAGE}"
      ;;
    none)
      log "skip image load/push; make sure cluster can pull ${IMAGE}"
      ;;
    *)
      printf 'unsupported LOAD_IMAGE=%s, use auto|kind|minikube|none\n' "${LOAD_IMAGE}" >&2
      exit 1
      ;;
  esac
}

RENDERED_MANIFEST=""

cleanup_rendered() {
  if [[ -n "${RENDERED_MANIFEST}" && -f "${RENDERED_MANIFEST}" ]]; then
    rm -f "${RENDERED_MANIFEST}"
  fi
}
trap cleanup_rendered EXIT

render_manifest() {
  local image_replacement model_replacement namespace_replacement
  RENDERED_MANIFEST="$(mktemp)"
  image_replacement="$(escape_sed_replacement "${IMAGE}")"
  model_replacement="$(escape_sed_replacement "${MODEL_ID}")"
  namespace_replacement="$(escape_sed_replacement "${NAMESPACE}")"

  sed \
    -e "s#${DEFAULT_IMAGE}#${image_replacement}#g" \
    -e "s#${DEFAULT_MODEL_ID}#${model_replacement}#g" \
    -e "s#name: llm-chat#name: ${namespace_replacement}#g" \
    -e "s#namespace: llm-chat#namespace: ${namespace_replacement}#g" \
    "${MANIFEST}" > "${RENDERED_MANIFEST}"

  printf '%s' "${RENDERED_MANIFEST}"
}

deploy_app() {
  require_cmd kubectl

  local rendered
  rendered="$(render_manifest)"

  log "apply RayService into namespace ${NAMESPACE}"
  kubectl apply -f "${rendered}"

  log "current resources"
  kubectl -n "${NAMESPACE}" get rayservice,pods,svc
}

print_next_steps() {
  cat <<EOF

Done.

Watch pods:
  kubectl -n ${NAMESPACE} get pods -w

Open chat UI:
  kubectl -n ${NAMESPACE} port-forward svc/${NAMESPACE}-serve-svc 8000:8000
  http://127.0.0.1:8000

Test concurrent requests:
  python scripts/load_test.py --url http://127.0.0.1:8000/chat --concurrency 8 --requests 24
EOF
}

main() {
  require_cmd kubectl
  build_image
  publish_or_load_image
  install_kuberay
  deploy_app
  print_next_steps

  if [[ "${PORT_FORWARD}" == "true" ]]; then
    log "start port-forward on http://127.0.0.1:8000"
    kubectl -n "${NAMESPACE}" port-forward "svc/${NAMESPACE}-serve-svc" 8000:8000
  fi
}

main "$@"
