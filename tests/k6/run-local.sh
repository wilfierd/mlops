#!/usr/bin/env bash
# Local k6 runner: port-forward to llm-chat-serve-svc, execute a k6 suite,
# and capture cluster/Ray/vLLM state before & after for forensic.
#
# Usage:
#   tests/k6/run-local.sh baseline       # default = baseline
#   tests/k6/run-local.sh load
#   tests/k6/run-local.sh stress
#   tests/k6/run-local.sh spike
#
# Env overrides:
#   NAMESPACE=llm-chat
#   SERVICE=llm-chat-serve-svc
#   LOCAL_PORT=8000
#   PROM_SNAPSHOT=1   # also dump vLLM /metrics + Ray /metrics into evidence
set -euo pipefail

SUITE="${1:-baseline}"
SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/k6-${SUITE}.js"

if [[ ! -f "${SCRIPT}" ]]; then
  echo "ERROR: unknown suite '${SUITE}'. Files in $(dirname "${SCRIPT}"):" >&2
  ls "$(dirname "${SCRIPT}")"/k6-*.js 2>/dev/null | sed 's|.*/k6-||; s|\.js$||' >&2
  exit 1
fi

NAMESPACE="${NAMESPACE:-llm-chat}"
SERVICE="${SERVICE:-llm-chat-serve-svc}"
LOCAL_PORT="${LOCAL_PORT:-8000}"
SERVICE_PORT="${SERVICE_PORT:-8000}"
BASE_URL="${BASE_URL:-http://127.0.0.1:${LOCAL_PORT}}"
OUT_DIR="${OUT_DIR:-reports/k6-${SUITE}-$(date +%Y%m%d-%H%M%S)}"
PROM_SNAPSHOT="${PROM_SNAPSHOT:-0}"
VLLM_PF_PIDS=()

mkdir -p "${OUT_DIR}"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "ERROR: kubectl required" >&2; exit 1
fi
if ! command -v k6 >/dev/null 2>&1; then
  echo "ERROR: k6 required. Install: https://grafana.com/docs/k6/latest/set-up/install-k6/" >&2
  exit 1
fi

cleanup() {
  if [[ -n "${PF_PID:-}" ]]; then
    kill "${PF_PID}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${VLLM_PF_PID:-}" ]]; then
    kill "${VLLM_PF_PID}" >/dev/null 2>&1 || true
  fi
  if ((${#VLLM_PF_PIDS[@]} > 0)); then
    for pid in "${VLLM_PF_PIDS[@]}"; do
      kill "${pid}" >/dev/null 2>&1 || true
    done
  fi
}
trap cleanup EXIT

{
  echo "k6 RAG /qa ${SUITE} test"
  echo "Started:        $(date -Is)"
  echo "Namespace:      ${NAMESPACE}"
  echo "Service:        ${SERVICE}"
  echo "Port-forward:   127.0.0.1:${LOCAL_PORT} -> svc/${SERVICE}:${SERVICE_PORT}"
  echo "BASE_URL:       ${BASE_URL}"
  echo "k6 script:      ${SCRIPT}"
  echo "Evidence dir:   ${OUT_DIR}"
} | tee "${OUT_DIR}/summary.txt"

kubectl config current-context > "${OUT_DIR}/kube-context.txt"
{
  kubectl -n "${NAMESPACE}" get rayservice -o wide
  echo
  kubectl -n "${NAMESPACE}" get statefulset -o wide
  echo
  kubectl -n "${NAMESPACE}" get pods -o wide
  echo
  kubectl -n "${NAMESPACE}" get svc -o wide
} > "${OUT_DIR}/before-objects.txt" 2>&1 || true
kubectl get nodes -L node-type,nvidia.com/gpu -o wide > "${OUT_DIR}/before-nodes.txt"
kubectl -n "${NAMESPACE}" get pvc -o wide > "${OUT_DIR}/before-pvc.txt" 2>&1 || true
kubectl -n kube-system get pods -l app.kubernetes.io/name=aws-cluster-autoscaler -o wide \
  > "${OUT_DIR}/before-cluster-autoscaler.txt" 2>&1 || true
kubectl -n "${NAMESPACE}" top pods > "${OUT_DIR}/before-top-pods.txt" 2>&1 || true

HEAD_POD_BEFORE="$(kubectl -n "${NAMESPACE}" get pod -l ray.io/node-type=head \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -n "${HEAD_POD_BEFORE}" ]]; then
  kubectl -n "${NAMESPACE}" exec -c ray-head "${HEAD_POD_BEFORE}" -- serve status \
    > "${OUT_DIR}/serve-status-before.txt" 2>&1 || true
fi

# Start port-forward in background
kubectl -n "${NAMESPACE}" port-forward "svc/${SERVICE}" "${LOCAL_PORT}:${SERVICE_PORT}" \
  > "${OUT_DIR}/port-forward.log" 2>&1 &
PF_PID="$!"

# Wait for /healthz to respond
echo "Waiting for /qa endpoint via /healthz..." | tee -a "${OUT_DIR}/summary.txt"
for _ in $(seq 1 30); do
  if curl -fsS "${BASE_URL}/healthz" > "${OUT_DIR}/healthz-before.json" 2> "${OUT_DIR}/healthz-before.err"; then
    break
  fi
  sleep 1
done

if ! curl -fsS "${BASE_URL}/healthz" > "${OUT_DIR}/healthz-before.json" 2> "${OUT_DIR}/healthz-before.err"; then
  echo "ERROR: /healthz unreachable through port-forward" | tee -a "${OUT_DIR}/summary.txt"
  cat "${OUT_DIR}/port-forward.log" >&2 || true
  exit 1
fi

# Optional: snapshot vLLM + Ray Prometheus metrics before/after the run
if [[ "${PROM_SNAPSHOT}" == "1" ]]; then
  i=0
  for pod in $(kubectl -n "${NAMESPACE}" get pod -l app.kubernetes.io/name=vllm-server -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
    port=$((18000 + i))
    kubectl -n "${NAMESPACE}" port-forward "pod/${pod}" "${port}:8000" \
      > "${OUT_DIR}/vllm-pf-${pod}.log" 2>&1 &
    VLLM_PF_PIDS+=("$!")
    sleep 2
    curl -fsS "http://127.0.0.1:${port}/metrics" > "${OUT_DIR}/vllm-metrics-before-${pod}.txt" 2>/dev/null || true
    i=$((i + 1))
  done
fi

# Run k6, capture stdout + JSON summary
set +e
BASE_URL="${BASE_URL}" k6 run \
  --summary-export "${OUT_DIR}/k6-summary.json" \
  --out json="${OUT_DIR}/k6-raw.json.gz" \
  "${SCRIPT}" | tee "${OUT_DIR}/k6.log"
K6_STATUS="${PIPESTATUS[0]}"
set -e

# Capture cluster state after the run
{
  kubectl -n "${NAMESPACE}" get rayservice -o wide
  echo
  kubectl -n "${NAMESPACE}" get statefulset -o wide
  echo
  kubectl -n "${NAMESPACE}" get pods -o wide
  echo
  kubectl -n "${NAMESPACE}" get svc -o wide
} > "${OUT_DIR}/after-objects.txt" 2>&1 || true
kubectl get nodes -L node-type,nvidia.com/gpu -o wide > "${OUT_DIR}/after-nodes.txt"
kubectl -n "${NAMESPACE}" get pvc -o wide > "${OUT_DIR}/after-pvc.txt" 2>&1 || true
kubectl -n kube-system logs deploy/cluster-autoscaler-aws-cluster-autoscaler --tail=300 \
  > "${OUT_DIR}/cluster-autoscaler.log" 2>&1 || true
kubectl -n "${NAMESPACE}" top pods > "${OUT_DIR}/after-top-pods.txt" 2>&1 || true
kubectl -n "${NAMESPACE}" get events --sort-by='.lastTimestamp' \
  > "${OUT_DIR}/events.txt" 2>&1 || true

# Ray Serve status snapshot from the head pod
HEAD_POD="$(kubectl -n "${NAMESPACE}" get pod -l ray.io/node-type=head \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -n "${HEAD_POD}" ]]; then
  kubectl -n "${NAMESPACE}" exec -c ray-head "${HEAD_POD}" -- serve status \
    > "${OUT_DIR}/serve-status-after.txt" 2>&1 || true
fi

if [[ "${PROM_SNAPSHOT}" == "1" ]]; then
  i=0
  for pod in $(kubectl -n "${NAMESPACE}" get pod -l app.kubernetes.io/name=vllm-server -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
    port=$((18000 + i))
    curl -fsS "http://127.0.0.1:${port}/metrics" > "${OUT_DIR}/vllm-metrics-after-${pod}.txt" 2>/dev/null || true
    i=$((i + 1))
  done
fi

{
  echo
  echo "Finished:       $(date -Is)"
  echo "k6 exit status: ${K6_STATUS}"
  echo
  echo "Key metrics (grepped from k6.log):"
  grep -E 'qa_duration_ms|qa_ttft_ms|qa_decode_ms|qa_error_rate|qa_slow_rate|qa_fallback_total|qa_backpressure_total|qa_empty_answer_total|http_req_duration|http_req_failed|http_reqs|iterations|vus_max' \
    "${OUT_DIR}/k6.log" || true
  echo
  echo "Pods/RayService after run:"
  cat "${OUT_DIR}/after-objects.txt"
  echo
  echo "Nodes after run:"
  cat "${OUT_DIR}/after-nodes.txt"
} | tee -a "${OUT_DIR}/summary.txt"

echo
echo "Evidence saved in: ${OUT_DIR}"
exit "${K6_STATUS}"
