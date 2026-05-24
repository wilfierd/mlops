/**
 * LOAD — Steady 4-VU traffic
 *
 * Goal     : Confirm 2x vLLM pods (max_num_seqs=8 each) handle a small demo
 *            audience without queuing. Validates GPU scale-out throughput at
 *            typical concurrent load.
 * Duration : ~5 minutes
 * VUs      : 4 constant (spread across 2 GPU pods by app round-robin)
 *
 * Expectations:
 *   - vllm:num_requests_waiting stays near 0 on both pods.
 *   - Per-user wall latency should stay closer to baseline than single-GPU load.
 *   - No 429 backpressure (QA_INFLIGHT semaphore = 16, well below).
 *   - No fallback reasons besides occasional no_hits if seed-doc retrieval misses.
 *
 * Watch on Grafana:
 *   - "QA In-Flight Requests": hovers around 4
 *   - "vLLM Queue Depth (waiting/running)": running split across pods, waiting=0
 *   - "vLLM Token Throughput": aggregate gen tokens/s higher than single GPU
 */

import { sleep } from 'k6';
import { qa, assertQAOK, healthCheck, printSummary } from './helpers.js';

export const options = {
  scenarios: {
    steady: {
      executor: 'constant-vus',
      vus: 4,
      duration: '5m',
    },
  },
  thresholds: {
    // 160 tokens at full output × 4-VU batched decode ≈ p95 25-30s on T4+3B.
    qa_duration_ms:  ['p(50)<22000', 'p(95)<30000', 'p(99)<35000'],
    qa_ttft_ms:      ['p(95)<2500'],
    qa_decode_ms:    ['p(95)<28000'],
    qa_error_rate:   ['rate<0.02'],
    qa_slow_rate:    ['rate<1.0'],   // sub-10s impossible at this profile; metric kept for visibility only
    http_req_failed: ['rate<0.02'],
  },
};

export function setup() {
  const h = healthCheck();
  if (h.status !== 200) console.warn(`Health check ${h.status}: ${h.body}`);
}

export default function () {
  const { res, answer, fallback } = qa();
  assertQAOK(res, answer, fallback);
  sleep(0.2);
}

export function handleSummary(data) {
  return { stdout: printSummary('LOAD (4 VU)', data) };
}
