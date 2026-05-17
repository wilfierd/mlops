/**
 * BASELINE — Single-VU latency benchmark
 *
 * Goal     : Measure cold + warm latency with NO concurrency.
 * Duration : ~2 minutes
 * VUs      : 1
 *
 * Output   : p50/p95/p99 latency for a single user, no queuing.
 *            This sets the "best case" lower bound for the model.
 */

import { sleep } from 'k6';
import {
  chat, assertChatOK, healthCheck, printSummary,
} from './helpers.js';

export const options = {
  scenarios: {
    baseline: {
      executor: 'constant-vus',
      vus: 1,
      duration: '2m',
    },
  },
  thresholds: {
    // Q4_K_M Qwen3-0.6B on 1.5 CPU expected ~1s p50, ~1.5s p95 for 64 tokens.
    chat_duration:     ['p(50)<2000', 'p(95)<3000', 'p(99)<5000'],
    chat_error_rate:   ['rate<0.01'],
    http_req_failed:   ['rate<0.01'],
  },
};

export function setup() {
  const h = healthCheck();
  if (h.status !== 200) console.warn(`Health check ${h.status}: ${h.body}`);
}

export default function () {
  const { res, answer } = chat({ maxNewTokens: 64, temperature: 0.2 });
  assertChatOK(res, answer);
  sleep(0.5); // tiny gap so we don't pin one actor's queue
}

export function handleSummary(data) {
  return { stdout: printSummary('BASELINE (1 VU)', data) };
}
