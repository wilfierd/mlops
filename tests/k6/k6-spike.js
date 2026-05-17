/**
 * SPIKE — Sudden traffic burst, measure cold-scale latency
 *
 * Goal     : Hit the system with a sudden 8-VU burst (vs gradual ramp).
 *            Quantify the time from spike onset until replicas catch up.
 * Duration : ~10 minutes
 * VUs      : 0 → 8 (immediate) → 8 (hold) → 0
 *
 * Differs from stress:
 *   - Stress = gradual ramp to find breaking point.
 *   - Spike  = step function: idle one moment, peak the next. Latency p99
 *              during the first 30-60s spike is the metric that matters.
 *
 * What you'll see:
 *   - For ~30s: huge queue, p99 latency ~5-30s as proxy waits for replica 3.
 *   - At ~3-5min mark: 2nd EC2 node Ready, replica 3-4 spawn, latency normalizes.
 */

import { sleep } from 'k6';
import { chat, assertChatOK, healthCheck, printSummary } from './helpers.js';

export const options = {
  scenarios: {
    spike: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '30s', target: 0 },   // idle baseline
        { duration: '5s',  target: 8 },   // SPIKE
        { duration: '6m',  target: 8 },   // hold so scale-up completes
        { duration: '30s', target: 0 },   // drop
        { duration: '2m',  target: 0 },   // observe replica downscale
      ],
      gracefulStop: '1m',
    },
  },
  thresholds: {
    chat_duration:   ['p(95)<30000', 'p(99)<60000'],
    chat_error_rate: ['rate<0.15'],
    http_req_failed: ['rate<0.15'],
  },
};

export function setup() {
  const h = healthCheck();
  console.log(`Pre-spike health: ${h.status}`);
}

export default function () {
  const { res, answer } = chat({ maxNewTokens: 64, temperature: 0.2, timeoutSec: 90 });
  assertChatOK(res, answer);
}

export function handleSummary(data) {
  return { stdout: printSummary('SPIKE (0 → 8 VU step)', data) };
}
