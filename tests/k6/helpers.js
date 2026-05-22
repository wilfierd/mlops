// Shared helpers for LLM chat k6 tests.
// All scripts import from here. BASE_URL defaults to localhost:8000 (the
// expected `kubectl port-forward svc/llm-chat-dev-serve-svc 8000:8000`
// target). Override via `-e BASE_URL=...`.

import http from 'k6/http';
import { check } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';
import { textSummary } from 'https://jslib.k6.io/k6-summary/0.0.2/index.js';

export const BASE_URL = __ENV.BASE_URL || 'http://127.0.0.1:8000';

// Default chat parameters. Override per-call via `chat({ prompt, maxNewTokens, ... })`.
export const DEFAULT_MAX_NEW_TOKENS = parseInt(__ENV.MAX_NEW_TOKENS || '64', 10);
export const DEFAULT_TEMPERATURE = parseFloat(__ENV.TEMPERATURE || '0.2');
export const DEFAULT_TOP_P = parseFloat(__ENV.TOP_P || '0.8');

const JSON_HEADERS = { 'Content-Type': 'application/json' };

// --- Custom metrics --------------------------------------------------------
export const chatDuration = new Trend('chat_duration', true);  // wall time / request (ms)
export const chatErrorRate = new Rate('chat_error_rate');
export const chatSlowRate = new Rate('chat_slow_rate');
export const tokenCount = new Counter('chat_tokens_generated_total');
export const emptyAnswers = new Counter('chat_empty_answers');
export const replicaHits = new Counter('chat_replica_hits');  // tagged by replica

// --- Endpoints -------------------------------------------------------------
export function healthCheck() {
  return http.get(`${BASE_URL}/health`, { tags: { name: 'health' } });
}

const PROMPTS = [
  'Viết một câu chào ngắn bằng tiếng Việt.',
  'Kể một câu chuyện ngắn về Sài Gòn trong 2 câu.',
  'Liệt kê 3 lý do tại sao Kubernetes phổ biến.',
  'Giải thích Ray Serve trong 2 câu ngắn.',
  'Cho tôi một fact thú vị về AWS.',
  'Tóm tắt khái niệm autoscaling.',
  'Tại sao nên dùng GGUF Q4_K_M trên CPU?',
  'Đặt 1 câu thơ về mùa thu.',
];

export function pickPrompt(index) {
  return PROMPTS[index % PROMPTS.length];
}

// Send POST /chat. Returns the http response so the caller can attach more checks.
export function chat({
  prompt = pickPrompt(__ITER),
  maxNewTokens = DEFAULT_MAX_NEW_TOKENS,
  temperature = DEFAULT_TEMPERATURE,
  topP = DEFAULT_TOP_P,
  timeoutSec = 60,
} = {}) {
  const body = JSON.stringify({
    messages: [{ role: 'user', content: prompt }],
    max_new_tokens: maxNewTokens,
    temperature,
    top_p: topP,
  });

  const res = http.post(`${BASE_URL}/chat`, body, {
    headers: JSON_HEADERS,
    timeout: `${timeoutSec}s`,
    tags: { name: 'chat' },
  });

  chatDuration.add(res.timings.duration);

  let answer = '';
  let replica = 'unknown';
  if (res.status === 200) {
    try {
      const parsed = res.json();
      answer = parsed.answer || '';
      replica = parsed.replica || 'unknown';
      tokenCount.add(maxNewTokens); // upper bound; actual tokens not reported
      if (!answer.trim()) emptyAnswers.add(1);
      replicaHits.add(1, { replica });
    } catch (e) {
      // body wasn't JSON
    }
  }
  return { res, answer, replica };
}

// --- Common checks ---------------------------------------------------------
export function assertChatOK(res, answer) {
  const ok = check(res, {
    'chat: status 200':       (r) => r.status === 200,
    'chat: has answer':       () => answer && answer.length > 0,
  });
  chatErrorRate.add(!ok);
  const fastEnough = check(res, {
    'chat: under 10s':        (r) => r.timings.duration < 10000,
  });
  chatSlowRate.add(!fastEnough);
  return ok;
}

// --- Summary ---------------------------------------------------------------
// Returns text summary suitable for stdout. Each test calls this from
// handleSummary so the runner script can grep key metrics.
export function printSummary(testName, data) {
  const banner =
    `\n=== ${testName} ===\n` +
    `BASE_URL: ${BASE_URL}\n` +
    `Duration: ${data.state.testRunDurationMs}ms\n`;

  // Replica distribution from custom tagged counter.
  const replicaBreakdown = (data.metrics.chat_replica_hits?.values?.count !== undefined)
    ? `\nReplica hits (total): ${data.metrics.chat_replica_hits.values.count}`
    : '';

  return banner + textSummary(data, { indent: ' ', enableColors: false }) + replicaBreakdown + '\n';
}
