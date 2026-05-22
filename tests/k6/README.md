# k6 performance tests for LLM chat

Adapted from `Test/scripts` style. Differences for LLM CPU workload:

- No auth flow (chat is unauthenticated).
- VU count 1..16 (not 50..300) — each request pins 1 actor for ~1s.
- Latency thresholds in seconds (steady load p95 < 5s, stress p95 < 15s, spike p95 < 30s).
- Tagged `replica` metric so load balance is visible.
- `chat_error_rate` tracks bad responses only; `chat_slow_rate` tracks responses over 10s.
- `max_ongoing_requests=1` per replica means >2 VUs queue at the proxy.

## Suites

| Suite | VUs | Duration | What it answers |
| --- | --- | --- | --- |
| `k6-baseline.js` | 1 constant | 2m | Single-user p50/p95/p99 |
| `k6-load.js` | 2 constant | 5m | Both actors evenly used? |
| `k6-stress.js` | 1→8 ramp + hold | 15m | When does autoscale trigger? |
| `k6-spike.js` | 0→8 step | 10m | Cold-spike p99 |

## Prereqs

```bash
# Install k6 (Fedora)
sudo dnf install k6
# or macOS
brew install k6
```

## Run (the way you actually want)

```bash
# Terminal 1: port-forward once
kubectl -n llm-chat port-forward svc/llm-chat-dev-serve-svc 8000:8000

# Terminal 2: run any suite directly
k6 run -e BASE_URL=http://127.0.0.1:8000 tests/k6/k6-load.js
k6 run -e BASE_URL=http://127.0.0.1:8000 tests/k6/k6-stress.js
```

`BASE_URL` defaults to `http://127.0.0.1:8000` if the env var is unset, so when
port-forward is already mapped to 8000 you can skip `-e`:

```bash
k6 run tests/k6/k6-baseline.js
```

For a public endpoint (ALB later):

```bash
k6 run -e BASE_URL=https://chat.example.com tests/k6/k6-load.js
```

Other env knobs (all optional, defined in `helpers.js`):

```bash
k6 run -e BASE_URL=... -e MAX_NEW_TOKENS=128 -e TEMPERATURE=0.7 tests/k6/k6-load.js
```

## What to watch while a test runs

3 terminals:

```bash
# Terminal A: live pod state
kubectl -n llm-chat get pods -w

# Terminal B: Grafana — "Ray Serve — LLM Chat" dashboard
kubectl -n monitoring port-forward svc/kube-prom-stack-grafana 3000:80
# http://127.0.0.1:3000

# Terminal C: actual k6 run
k6 run tests/k6/k6-stress.js
```

Look for:
- Active Serve Replicas: 2 → 3 → 4
- Ongoing requests per replica: spike > 1.0
- New worker pod in `kubectl get pods`
- 2nd EC2 m7g.xlarge joining (`kubectl get nodes -L ray.io/node-type`)

## Optional — wrapper script

`run-local.sh` does port-forward + before/after cluster snapshots + JSON
export into `reports/k6-<suite>-<timestamp>/`. Use only if you want
audit-trail evidence for the eval. For day-to-day iteration just use plain
`k6 run`.

```bash
./tests/k6/run-local.sh baseline
./tests/k6/run-local.sh stress
```

## Comparing runs (with --summary-export)

```bash
k6 run --summary-export reports/baseline.json tests/k6/k6-baseline.js
k6 run --summary-export reports/stress.json  tests/k6/k6-stress.js

for r in reports/*.json; do
  echo "$r"
  jq '.metrics.chat_duration.values | {p50, "p(95)", "p(99)", count}' "$r"
done
```

## Tuning load profile

Each suite's `options.stages` is short for lab iteration. Bump durations
in the .js file when you want a real benchmark publish.

To change prompts, edit `PROMPTS` array in `helpers.js`.

## Note on port-forward fidelity

`kubectl port-forward` uses one SPDY tunnel; absolute numbers include
~10-20ms of port-forward overhead per request. Fine for relative
comparison between runs. For published benchmark numbers, deploy k6 as a
K8s Job inside the cluster (similar to `Test/scripts/k8s-k6-stress-test.sh`).
