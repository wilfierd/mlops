/**
 * SPIKE — Step burst from idle to full batch, measure cold-batch latency
 *
 * Goal     : Hit the system with a sudden 16-VU step (vs gradual ramp).
 *            Quantify TTFT degradation when vLLM goes from idle → full batch
 *            in one moment.
 *
 * Duration : ~10 minutes
 * VUs      : 0 → 16 (step) → 16 (hold) → 0
 *
 * Differs from stress:
 *   - Stress = gradual ramp 1→20 to find shedding point.
 *   - Spike  = step function: idle one moment, exactly-full the next.
 *              We stop at 16 (not over) to isolate batch-warmup cost from
 *              backpressure shedding.
 *
 * What you'll see:
 *   - First 5–10 s after spike: TTFT p99 spikes (vLLM rebuilds CUDA graph for
 *     larger batch, KV cache repopulates). Wall p99 can hit 20–40s briefly.
 *   - After ~30 s: batch settles, throughput stabilizes around bench numbers.
 *   - No 429 expected — 16 VUs is exactly QA_INFLIGHT limit (off-by-one tolerance
 *     in semaphore acquisition; brief race may cause ≤1% 429).
 *
 * Watch on Grafana:
 *   - "vLLM TTFT": p95 spike at t≈30s, recovers by t≈60s.
 *   - "vLLM Prefill vs Decode Time p95": prefill ratio drops as batch fills.
 *   - "QA Per-Step p95 Latency": llm step is the only one that should move.
 */

import { qa, assertQAAccept, healthCheck, printSummary } from './helpers.js';

export const options = {
  scenarios: {
    spike: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '30s', target: 0 },    // idle baseline
        { duration: '5s',  target: 16 },   // SPIKE to full vLLM batch
        { duration: '6m',  target: 16 },   // hold so batch warmup completes
        { duration: '30s', target: 0 },    // drop
        { duration: '2m',  target: 0 },    // observe recovery
      ],
      gracefulStop: '1m',
    },
  },
  thresholds: {
    // Wide ceiling for first 30s spike absorption; should settle after.
    qa_duration_ms:  ['p(95)<40000', 'p(99)<60000'],
    qa_error_rate:   ['rate<0.05'],
    // 429 is acceptable during edge races at QA_INFLIGHT=16; use
    // qa_error_rate instead of http_req_failed to avoid false failures.
  },
};

export function setup() {
  const h = healthCheck();
  console.log(`Pre-spike health: ${h.status}`);
}

export default function () {
  const { res } = qa({ timeoutSec: 90 });
  assertQAAccept(res);
}

export function handleSummary(data) {
  return { stdout: printSummary('SPIKE (0 → 16 VU step)', data) };
}
