/**
 * STRESS — Push past 2 replicas to trigger autoscale
 *
 * Goal     : Drive load beyond baseline capacity (>2 ongoing requests).
 *            Ray Serve should scale ChatModel replicas from 2 toward max=4.
 *            For replica 3-4, KubeRay needs a 2nd worker pod, which needs a
 *            2nd EC2 node from the worker MNG.
 * Duration : ~15 minutes (long enough for AWS EC2 scale-up)
 * VUs      : 2 → 8 → 8 (hold) → 0
 *
 * What to watch (Grafana / Ray Dashboard):
 *   - "Active Serve Replicas": 2 → 3 → 4
 *   - "Ongoing requests per replica": spike above 1.0, then settles
 *   - Pods view: worker pod count: 1 → 2
 *   - Nodes: m7g.xlarge worker count: 1 → 2 (autoscaled)
 *
 * Notes:
 *   - max_ongoing_requests=1 per replica means requests over capacity queue at the proxy.
 *   - p99 will spike on the very first replica-3 request (cold spawn ~10s on cached image).
 *   - If MNG max=2, replicas 5-8 stay pending — that's expected for the cost guard.
 */

import { sleep } from 'k6';
import { chat, assertChatOK, healthCheck, printSummary } from './helpers.js';

export const options = {
  scenarios: {
    ramp_and_hold: {
      executor: 'ramping-vus',
      startVUs: 1,
      stages: [
        { duration: '2m',  target: 2 },   // warm — same as load test
        { duration: '2m',  target: 4 },   // 1st queue forms; Ray Serve scales replica 3
        { duration: '2m',  target: 6 },   // KubeRay creates 2nd worker pod; EKS scales node
        { duration: '5m',  target: 8 },   // hold at peak — burn through scale-up
        { duration: '2m',  target: 0 },   // ramp down — observe replica downscale (~2min idle)
        { duration: '2m',  target: 0 },
      ],
      gracefulStop: '1m',
    },
  },
  thresholds: {
    // Looser — under stress, scale-up latency is real and tolerated.
    chat_duration:   ['p(95)<15000', 'p(99)<45000'],
    chat_error_rate: ['rate<0.10'],
    http_req_failed: ['rate<0.10'],
  },
};

export function setup() {
  const h = healthCheck();
  console.log(`Pre-stress health: ${h.status}`);
}

export default function () {
  const { res, answer } = chat({ maxNewTokens: 64, temperature: 0.2, timeoutSec: 60 });
  assertChatOK(res, answer);
  // No sleep — we want to keep replicas saturated to force scale.
}

export function handleSummary(data) {
  return { stdout: printSummary('STRESS (2 → 8 VU)', data) };
}
