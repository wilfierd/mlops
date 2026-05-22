/**
 * LOAD — Steady 2-VU traffic (saturate both actors in 1 worker pod)
 *
 * Goal     : Confirm 2 replicas can each handle 1 ongoing request without queuing.
 * Duration : ~5 minutes
 * VUs      : 2 constant (matches min_replicas + max_ongoing_requests=1 per replica)
 *
 * Expectations:
 *   - Each request lands on one of the 2 actors; replica distribution should be roughly 50/50.
 *   - Latency should stay close to baseline (single-VU) because no queue forms.
 *   - No autoscale should trigger (ongoing/replica stays at 1.0).
 */

import { sleep } from 'k6';
import { chat, assertChatOK, healthCheck, printSummary } from './helpers.js';

export const options = {
  scenarios: {
    steady: {
      executor: 'constant-vus',
      vus: 2,
      duration: '5m',
    },
  },
  thresholds: {
    chat_duration:   ['p(50)<4000', 'p(95)<5000', 'p(99)<8000'],
    chat_error_rate: ['rate<0.02'],
    http_req_failed: ['rate<0.02'],
  },
};

export function setup() {
  const h = healthCheck();
  if (h.status !== 200) console.warn(`Health check ${h.status}: ${h.body}`);
}

export default function () {
  const { res, answer } = chat({ maxNewTokens: 64, temperature: 0.2 });
  assertChatOK(res, answer);
  sleep(0.2);
}

export function handleSummary(data) {
  return { stdout: printSummary('LOAD (2 VU)', data) };
}
