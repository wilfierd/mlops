/**
 * BASELINE — Single-VU /qa latency benchmark
 *
 * Goal     : Measure cold + warm latency on T4 + Qwen2.5-3B-AWQ with no concurrency.
 *            This sets the "best case" lower bound for the model.
 * Duration : ~2 minutes
 * VUs      : 1
 *
 * Expectations (T4 + 3B AWQ + max_tokens=160, no early-stop):
 *   - TTFT (server-reported) ~400–800 ms (measured ~607 ms p50).
 *   - Decode ~8–10 tok/s (measured 9.8). At full 160 tokens ≈ 16–19 s.
 *   - Wall p50 ~13–15 s, p95 ~19–20 s (matches first baseline run on T4).
 *   - Demo prioritizes answer quality (3-4 bullets) over latency budget.
 *
 * Thresholds are calibrated to actual measurements with headroom for
 * variance — NOT to an SLO. If you want sub-10s for demo, that requires
 * either model swap (back to even smaller) or GPU upgrade (L4/A10G).
 */

import { sleep } from 'k6';
import { qa, assertQAOK, healthCheck, printSummary } from './helpers.js';

export const options = {
  scenarios: {
    baseline: {
      executor: 'constant-vus',
      vus: 1,
      duration: '2m',
    },
  },
  thresholds: {
    qa_duration_ms:  ['p(50)<17000', 'p(95)<22000', 'p(99)<25000'],
    qa_ttft_ms:      ['p(95)<1500'],
    qa_decode_ms:    ['p(95)<21000'],
    qa_error_rate:   ['rate<0.01'],
    http_req_failed: ['rate<0.01'],
  },
};

export function setup() {
  const h = healthCheck();
  if (h.status !== 200) console.warn(`Health check ${h.status}: ${h.body}`);
}

export default function () {
  const { res, answer, fallback } = qa();
  assertQAOK(res, answer, fallback);
  sleep(0.5);
}

export function handleSummary(data) {
  return { stdout: printSummary('BASELINE (1 VU)', data) };
}
