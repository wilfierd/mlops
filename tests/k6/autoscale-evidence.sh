#!/usr/bin/env bash
# Capture Kubernetes autoscaling evidence for the RAG stack.
#
# This is intentionally separate from k6:
# - k6 proves request behavior under load.
# - this script proves Kubernetes node autoscaling happened (or why it did not).
#
# Recommended flow:
#   1. GPU node group min=1/max=2 and Cluster Autoscaler installed.
#   2. `make -C infra vllm-up` creates vllm-server replicas=2.
#   3. vllm-server-1 is Pending until Cluster Autoscaler adds GPU node #2.
#   4. Run this script while waiting, or immediately after scale-up.
set -euo pipefail

NAMESPACE="${NAMESPACE:-llm-chat}"
OUT_DIR="${OUT_DIR:-reports/autoscale-$(date +%Y%m%d-%H%M%S)}"
TIMEOUT="${TIMEOUT:-900s}"
case "${TIMEOUT}" in
  *s) TIMEOUT_SECONDS="${TIMEOUT%s}" ;;
  *m) TIMEOUT_SECONDS="$(( ${TIMEOUT%m} * 60 ))" ;;
  *) TIMEOUT_SECONDS="${TIMEOUT}" ;;
esac

mkdir -p "${OUT_DIR}"

log() {
  printf '[autoscale] %s\n' "$*" | tee -a "${OUT_DIR}/summary.txt"
}

capture() {
  local name="$1"
  shift
  log "capture ${name}"
  "$@" > "${OUT_DIR}/${name}.txt" 2>&1 || true
}

log "Started: $(date -Is)"
log "Namespace: ${NAMESPACE}"
log "Timeout: ${TIMEOUT}"
log "Output: ${OUT_DIR}"

capture kube-context kubectl config current-context
capture nodes-before kubectl get nodes -L node-type,nvidia.com/gpu -o wide
capture pods-before kubectl -n "${NAMESPACE}" get pods -o wide
capture pvc-before kubectl -n "${NAMESPACE}" get pvc -o wide
capture rayservice-before kubectl -n "${NAMESPACE}" get rayservice -o wide
capture nodegroup-before aws eks describe-nodegroup \
  --cluster-name llm-chat-dev \
  --nodegroup-name "$(aws eks list-nodegroups --cluster-name llm-chat-dev --region us-west-2 --query 'nodegroups[?contains(@, `gpu`)] | [0]' --output text)" \
  --region us-west-2 \
  --query 'nodegroup.{name:nodegroupName,status:status,scalingConfig:scalingConfig,instanceTypes:instanceTypes,capacityType:capacityType,health:health}' \
  --output json

log "Waiting for 2 Ready GPU nodes..."
end_epoch=$(( $(date +%s) + TIMEOUT_SECONDS ))
GPU_READY_COUNT=0
while (( $(date +%s) < end_epoch )); do
  GPU_READY_COUNT="$(kubectl get nodes -l node-type=gpu-worker --no-headers 2>/dev/null | awk '$2=="Ready"{n++} END{print n+0}')"
  if [[ "${GPU_READY_COUNT}" -ge 2 ]]; then
    break
  fi
  sleep 10
done
echo "ready_gpu_nodes=${GPU_READY_COUNT}" > "${OUT_DIR}/wait-gpu-nodes.txt"
kubectl get nodes -l node-type=gpu-worker -o wide >> "${OUT_DIR}/wait-gpu-nodes.txt" 2>&1 || true
log "Ready GPU nodes: ${GPU_READY_COUNT}"

log "Waiting for vllm-server-1 Ready..."
kubectl -n "${NAMESPACE}" wait --for=condition=Ready pod/vllm-server-1 --timeout="${TIMEOUT}" \
  > "${OUT_DIR}/wait-vllm-server-1.txt" 2>&1 || true

GPU_READY_COUNT="$(kubectl get nodes -l node-type=gpu-worker --no-headers 2>/dev/null | awk '$2=="Ready"{n++} END{print n+0}')"
log "Ready GPU nodes after vLLM wait: ${GPU_READY_COUNT}"

capture nodes-after kubectl get nodes -L node-type,nvidia.com/gpu -o wide
capture pods-after kubectl -n "${NAMESPACE}" get pods -o wide
capture pvc-after kubectl -n "${NAMESPACE}" get pvc -o wide
capture events kubectl -n "${NAMESPACE}" get events --sort-by=.lastTimestamp
capture ca-pods kubectl -n kube-system get pods -l app.kubernetes.io/name=aws-cluster-autoscaler -o wide
capture ca-logs kubectl -n kube-system logs deploy/cluster-autoscaler-aws-cluster-autoscaler --tail=500
capture nodegroup-after aws eks describe-nodegroup \
  --cluster-name llm-chat-dev \
  --nodegroup-name "$(aws eks list-nodegroups --cluster-name llm-chat-dev --region us-west-2 --query 'nodegroups[?contains(@, `gpu`)] | [0]' --output text)" \
  --region us-west-2 \
  --query 'nodegroup.{name:nodegroupName,status:status,scalingConfig:scalingConfig,instanceTypes:instanceTypes,capacityType:capacityType,health:health}' \
  --output json

{
  echo
  echo "Key evidence:"
  echo "- nodes-before.txt / nodes-after.txt: GPU node count transition"
  echo "- wait-vllm-server-1.txt: second vLLM pod scheduling result"
  echo "- ca-logs.txt: Cluster Autoscaler scale-up decision"
  echo "- nodegroup-before.txt / nodegroup-after.txt: EKS desired capacity"
  echo
  echo "Finished: $(date -Is)"
} | tee -a "${OUT_DIR}/summary.txt"

if [[ "${GPU_READY_COUNT}" -lt 2 ]]; then
  log "WARN: fewer than 2 GPU nodes are Ready. Check ca-logs.txt and nodegroup-after.txt."
  exit 1
fi

log "Autoscale evidence capture complete."
