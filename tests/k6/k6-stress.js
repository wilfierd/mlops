/**
 * STRESS — Ramp up to saturate vLLM batch, then push past QA_INFLIGHT
 *
 * Goal     : Find the point where the system starts shedding load.
 *            Current architecture has RagApi autoscale 1→2 and 2 vLLM GPU
 *            replicas, so this measures the scale-out ceiling.
 *
 *   - vLLM batch capacity: 2 pods × max_num_seqs 8 = 16
 *   - RagApi semaphore   : QA_INFLIGHT = 16  (returns 429 on overflow)
 *
 * Duration : ~15 minutes
 * VUs      : 1 → 8 → 16 → 20 → 0  (20 deliberately exceeds the 16 semaphore)
 *
 * What to watch (Grafana RAG Pipeline):
 *   - "QA In-Flight Requests": climbs toward 16, holds.
 *   - "vLLM Queue Depth (waiting/running)": running≈8 per pod, waiting>0 once VUs > 16.
 *   - "QA Request Rate by Status": `fallback` line jumps (backpressure) at VU=20.
 *   - "QA Fallback Rate by Reason": backpressure spike.
 *   - Wall p95 climbs past 20s under batched decode pressure.
 *
 * Pass/fail framing:
 *   - Stress tolerates 429s (backpressure is the SLO; better to reject than queue
 *     forever). qa_error_rate excludes 429 by design (see assertQAAccept).
 *   - System should NOT 5xx; that would be a real bug.
 */

import { sleep } from 'k6';
import { qa, assertQAAccept, healthCheck, printSummary } from './helpers.js';

export const options = {
  scenarios: {
    ramp_and_hold: {
      executor: 'ramping-vus',
      startVUs: 1,
      stages: [
        { duration: '2m',  target: 4 },    // warm — same as load test
        { duration: '2m',  target: 8 },    // half of vLLM batch — no queue yet
        { duration: '2m',  target: 16 },   // exactly fills vLLM batch
        { duration: '5m',  target: 20 },   // 4 over semaphore → expect 429s
        { duration: '2m',  target: 0 },    // ramp down
        { duration: '2m',  target: 0 },    // observe recovery
      ],
      gracefulStop: '1m',
    },
  },
  thresholds: {
    // Looser ceiling — batched decode + queueing slows individual users.
    qa_duration_ms:  ['p(95)<25000', 'p(99)<45000'],
    qa_error_rate:   ['rate<0.05'],   // 5% true errors max (429 NOT counted)
    http_req_failed: ['rate<0.05'],
  },
};

export function setup() {
  const h = healthCheck();
  console.log(`Pre-stress health: ${h.status}`);
}

export default function () {
  // 90s timeout — at 20 VUs the slowest tail can run long. We accept 429.
  const { res } = qa({ timeoutSec: 90 });
  assertQAAccept(res);
  // No sleep — keep vLLM batch saturated.
}

export function handleSummary(data) {
  return { stdout: printSummary('STRESS (1 → 20 VU)', data) };
}
