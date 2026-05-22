#!/usr/bin/env bash
# Local k6 runner: port-forward to llm-chat-dev-serve-svc and execute a k6
# script while capturing cluster state before/after.
#
# Usage:
#   tests/k6/run-local.sh baseline       # default = baseline
#   tests/k6/run-local.sh load
#   tests/k6/run-local.sh stress
#   tests/k6/run-local.sh spike
#
# Env overrides:
#   NAMESPACE=llm-chat
#   SERVICE=llm-chat-dev-serve-svc
#   LOCAL_PORT=8000
set -euo pipefail

SUITE="${1:-baseline}"
SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/k6-${SUITE}.js"

if [[ ! -f "${SCRIPT}" ]]; then
  echo "ERROR: unknown suite '${SUITE}'. Files in $(dirname "${SCRIPT}"):" >&2
  ls "$(dirname "${SCRIPT}")"/k6-*.js 2>/dev/null | sed 's|.*/k6-||; s|\.js$||' >&2
  exit 1
fi

NAMESPACE="${NAMESPACE:-llm-chat}"
SERVICE="${SERVICE:-llm-chat-dev-serve-svc}"
LOCAL_PORT="${LOCAL_PORT:-8000}"
SERVICE_PORT="${SERVICE_PORT:-8000}"
BASE_URL="${BASE_URL:-http://127.0.0.1:${LOCAL_PORT}}"
OUT_DIR="${OUT_DIR:-reports/k6-${SUITE}-$(date +%Y%m%d-%H%M%S)}"

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
}
trap cleanup EXIT

{
  echo "k6 LLM chat ${SUITE} test"
  echo "Started:        $(date -Is)"
  echo "Namespace:      ${NAMESPACE}"
  echo "Service:        ${SERVICE}"
  echo "Port-forward:   127.0.0.1:${LOCAL_PORT} -> svc/${SERVICE}:${SERVICE_PORT}"
  echo "BASE_URL:       ${BASE_URL}"
  echo "k6 script:      ${SCRIPT}"
  echo "Evidence dir:   ${OUT_DIR}"
} | tee "${OUT_DIR}/summary.txt"

kubectl config current-context > "${OUT_DIR}/kube-context.txt"
kubectl -n "${NAMESPACE}" get rayservice,pods,svc -o wide > "${OUT_DIR}/before-objects.txt"
kubectl -n "${NAMESPACE}" top pods > "${OUT_DIR}/before-top-pods.txt" 2>&1 || true

# Start port-forward in background
kubectl -n "${NAMESPACE}" port-forward "svc/${SERVICE}" "${LOCAL_PORT}:${SERVICE_PORT}" \
  > "${OUT_DIR}/port-forward.log" 2>&1 &
PF_PID="$!"

# Wait for chat endpoint to respond
echo "Waiting for chat endpoint..." | tee -a "${OUT_DIR}/summary.txt"
for _ in $(seq 1 30); do
  if curl -fsS "${BASE_URL}/health" > "${OUT_DIR}/health-before.json" 2> "${OUT_DIR}/health-before.err"; then
    break
  fi
  sleep 1
done

if ! curl -fsS "${BASE_URL}/health" > "${OUT_DIR}/health-before.json" 2> "${OUT_DIR}/health-before.err"; then
  echo "ERROR: /health unreachable through port-forward" | tee -a "${OUT_DIR}/summary.txt"
  cat "${OUT_DIR}/port-forward.log" >&2 || true
  exit 1
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
kubectl -n "${NAMESPACE}" get rayservice,pods,svc -o wide > "${OUT_DIR}/after-objects.txt"
kubectl -n "${NAMESPACE}" top pods > "${OUT_DIR}/after-top-pods.txt" 2>&1 || true
kubectl -n "${NAMESPACE}" get events --sort-by='.lastTimestamp' \
  > "${OUT_DIR}/events.txt" 2>&1 || true

# Pull last replica logs for forensic
HEAD_POD="$(kubectl -n "${NAMESPACE}" get pod -l ray.io/node-type=head \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -n "${HEAD_POD}" ]]; then
  kubectl -n "${NAMESPACE}" exec -c ray-head "${HEAD_POD}" -- serve status \
    > "${OUT_DIR}/serve-status-after.txt" 2>&1 || true
fi

{
  echo
  echo "Finished:       $(date -Is)"
  echo "k6 exit status: ${K6_STATUS}"
  echo
  echo "Key metrics (grepped from k6.log):"
  grep -E 'chat_duration|chat_error_rate|chat_slow_rate|http_req_duration|http_req_failed|http_reqs|iterations|vus_max|chat_replica_hits' \
    "${OUT_DIR}/k6.log" || true
  echo
  echo "Pods/RayService after run:"
  cat "${OUT_DIR}/after-objects.txt"
} | tee -a "${OUT_DIR}/summary.txt"

echo
echo "Evidence saved in: ${OUT_DIR}"
exit "${K6_STATUS}"
