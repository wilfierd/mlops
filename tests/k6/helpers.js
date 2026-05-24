// Shared helpers for RAG /qa k6 tests.
//
// All scripts import from here. BASE_URL defaults to localhost:8000 —
// the expected target of `kubectl -n llm-chat port-forward svc/llm-chat-serve-svc 8000:8000`.
// Override via `-e BASE_URL=...`.
//
// What changed vs the legacy /chat helpers:
//   - Endpoint: /qa (question-based RAG) instead of /chat (legacy messages).
//   - Schema: { question, top_k, score_threshold } not { messages, max_new_tokens }.
//   - Trends: parses latency_ms.ttft / latency_ms.decode from the response so
//     k6 reports prefill vs decode split (matches the app's structured log).
//   - Fallback tracking: 429 backpressure, no_hits, llm_timeout, empty_answer
//     are first-class metrics, not lumped into "errors".
//   - X-Request-Id is set per request so a k6 row can be grepped in rag-logs.

import http from 'k6/http';
import { check } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';
import { textSummary } from 'https://jslib.k6.io/k6-summary/0.0.2/index.js';

export const BASE_URL = __ENV.BASE_URL || 'http://127.0.0.1:8000';
export const DEFAULT_TOP_K = parseInt(__ENV.TOP_K || '3', 10);
export const DEFAULT_SCORE_THRESHOLD = parseFloat(__ENV.SCORE_THRESHOLD || '0.5');

const JSON_HEADERS = { 'Content-Type': 'application/json' };

// --- Custom metrics --------------------------------------------------------
export const qaDuration = new Trend('qa_duration_ms', true);   // wall time per request
export const qaTtft = new Trend('qa_ttft_ms', true);            // server-reported TTFT
export const qaDecode = new Trend('qa_decode_ms', true);        // server-reported decode time
export const qaErrorRate = new Rate('qa_error_rate');
export const qaSlowRate = new Rate('qa_slow_rate');             // > 10s wall time
export const qaFallback = new Counter('qa_fallback_total');     // tagged by reason
export const qaBackpressure = new Counter('qa_backpressure_total');  // HTTP 429
export const qaEmptyAnswer = new Counter('qa_empty_answer_total');

// --- Question pool ---------------------------------------------------------
// Tied to data/seed/*.md fixtures so retrieval has real hits (top_score > 0.5).
// Keep mixed: factoid, "what is", "how to", multi-concept.
const QUESTIONS = [
  'RAG là gì?',
  'Ray Serve dùng để làm gì?',
  'Qdrant lưu trữ dữ liệu kiểu gì?',
  'Vector embedding dùng để làm gì?',
  'Làm sao để scale Ray Serve replicas?',
  'Qdrant có hỗ trợ filter metadata không?',
  'RAG khác fine-tuning ở điểm nào?',
  'Tại sao similarity search dùng cosine?',
];

export function pickQuestion(index) {
  return QUESTIONS[index % QUESTIONS.length];
}

// --- Endpoints -------------------------------------------------------------
export function healthCheck() {
  return http.get(`${BASE_URL}/healthz`, { tags: { name: 'healthz' } });
}

function genRequestId() {
  // hex token good enough to grep in app logs; not a real UUID, on purpose.
  const rand = Math.random().toString(16).slice(2, 12);
  return `k6-${rand}-vu${__VU || 0}-it${__ITER || 0}`;
}

// Send POST /qa. Returns http response + parsed answer/fallback + correlation id.
export function qa({
  question = pickQuestion(__ITER),
  topK = DEFAULT_TOP_K,
  scoreThreshold = DEFAULT_SCORE_THRESHOLD,
  timeoutSec = 60,
} = {}) {
  const body = JSON.stringify({
    question,
    top_k: topK,
    score_threshold: scoreThreshold,
  });

  const reqId = genRequestId();
  const res = http.post(`${BASE_URL}/qa`, body, {
    headers: { ...JSON_HEADERS, 'X-Request-Id': reqId },
    timeout: `${timeoutSec}s`,
    tags: { name: 'qa' },
  });

  qaDuration.add(res.timings.duration);

  let parsed = null;
  let answer = '';
  let fallback = null;

  if (res.status === 200) {
    try {
      parsed = res.json();
      answer = (parsed && parsed.answer) || '';
      fallback = (parsed && parsed.fallback_reason) || null;

      if (parsed && parsed.latency_ms) {
        if (typeof parsed.latency_ms.ttft === 'number') qaTtft.add(parsed.latency_ms.ttft);
        if (typeof parsed.latency_ms.decode === 'number') qaDecode.add(parsed.latency_ms.decode);
      }
      if (fallback) {
        qaFallback.add(1, { reason: fallback });
      }
      if (!answer.trim() && !fallback) {
        qaEmptyAnswer.add(1);
      }
    } catch (e) {
      // body wasn't JSON — leave answer empty, assertQAOK will mark error
    }
  } else if (res.status === 429) {
    qaBackpressure.add(1);
  }

  return { res, answer, fallback, parsed, reqId };
}

// --- Common checks ---------------------------------------------------------
// Strict assertion for baseline/load: require 200 + non-empty answer + no fallback.
export function assertQAOK(res, answer, fallback) {
  const ok = check(res, {
    'qa: status 200':  (r) => r.status === 200,
    'qa: has answer':  () => answer && answer.length > 0,
    'qa: no fallback': () => fallback === null,
  });
  qaErrorRate.add(!ok);
  const fast = check(res, {
    'qa: under 10s':   (r) => r.timings.duration < 10000,
  });
  qaSlowRate.add(!fast);
  return ok;
}

// Tolerant assertion for stress/spike: 429 backpressure is acceptable signal,
// not a real error. Only true errors (5xx, parse fail, timeout) count.
export function assertQAAccept(res) {
  const ok = check(res, {
    'qa: 200 or 429': (r) => r.status === 200 || r.status === 429,
  });
  qaErrorRate.add(!ok);
  const fast = check(res, {
    'qa: under 10s':  (r) => r.timings.duration < 10000,
  });
  qaSlowRate.add(!fast);
  return ok;
}

// --- Summary ---------------------------------------------------------------
export function printSummary(testName, data) {
  const banner =
    `\n=== ${testName} ===\n` +
    `BASE_URL: ${BASE_URL}\n` +
    `Duration: ${data.state.testRunDurationMs}ms\n`;

  const fb = data.metrics.qa_fallback_total?.values?.count || 0;
  const bp = data.metrics.qa_backpressure_total?.values?.count || 0;
  const empty = data.metrics.qa_empty_answer_total?.values?.count || 0;
  const tail =
    `\nFallbacks: ${fb}   Backpressure (429): ${bp}   Empty answers: ${empty}\n`;

  return banner + textSummary(data, { indent: ' ', enableColors: false }) + tail;
}
