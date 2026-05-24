"""Ray Serve metrics for the RAG pipeline.

Instantiate RagMetrics() inside RagApi.__init__ so each replica gets its
own per-actor metric registration (required by ray.util.metrics).
"""
from __future__ import annotations

from ray.util.metrics import Counter, Gauge, Histogram

_QA_LATENCY_BUCKETS = [100, 500, 1_000, 2_000, 5_000, 10_000, 20_000, 40_000]
_STEP_LATENCY_BUCKETS = [10, 50, 100, 500, 1_000, 2_000, 5_000, 15_000]
_TTFT_BUCKETS = [50, 100, 200, 400, 800, 1_500, 3_000, 6_000]
_COMPLETION_TOK_BUCKETS = [16, 32, 64, 96, 128, 160, 200, 256, 384, 512]
_SCORE_BUCKETS = [0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0]
_HITS_BUCKETS = [0, 1, 3, 5, 8, 12, 16, 20]


class RagMetrics:
    def __init__(self) -> None:
        self.qa_requests = Counter(
            "rag_qa_requests_total",
            description="Total POST /qa requests",
            tag_keys=("status",),  # ok | fallback | error
        )
        self.qa_latency = Histogram(
            "rag_qa_latency_ms",
            description="End-to-end QA latency ms",
            boundaries=_QA_LATENCY_BUCKETS,
        )
        self.qa_step_latency = Histogram(
            "rag_qa_step_latency_ms",
            description="Per-step QA latency ms (embed/qdrant/mmr/llm)",
            boundaries=_STEP_LATENCY_BUCKETS,
            tag_keys=("step",),
        )
        self.qa_fallbacks = Counter(
            "rag_qa_fallback_total",
            description="QA fallback events by reason",
            # Known reasons: no_hits | embed_timeout | qdrant_timeout |
            # llm_timeout | backpressure | empty_answer
            tag_keys=("reason",),
        )
        self.qa_inflight = Gauge(
            "rag_qa_inflight",
            description="In-flight QA requests (semaphore occupancy)",
        )
        self.ingest_docs = Counter(
            "rag_ingest_docs_total",
            description="Documents submitted via POST /documents",
            tag_keys=("result",),  # accepted | already_ready | already_processing
        )
        self.ingest_chunks = Counter(
            "rag_ingest_chunks_total",
            description="Chunks written to Qdrant by ingest_task",
        )
        # P-observability: TTFT split + retrieval quality + answer size
        self.qa_ttft_ms = Histogram(
            "rag_qa_ttft_ms",
            description="vLLM time-to-first-token ms (streaming first content chunk)",
            boundaries=_TTFT_BUCKETS,
        )
        self.qa_completion_tokens = Histogram(
            "rag_qa_completion_tokens",
            description="vLLM completion_tokens per /qa (from usage)",
            boundaries=_COMPLETION_TOK_BUCKETS,
        )
        self.qa_retrieval_top_score = Histogram(
            "rag_retrieval_top_score",
            description="Top Qdrant hit score after score_threshold",
            boundaries=_SCORE_BUCKETS,
        )
        self.qa_retrieval_hits_raw = Histogram(
            "rag_retrieval_hits_raw",
            description="Qdrant hits above score_threshold (pre-MMR)",
            boundaries=_HITS_BUCKETS,
        )
        self.qa_retrieval_hits_selected = Histogram(
            "rag_retrieval_hits_selected",
            description="Hits passed to LLM after MMR rerank",
            boundaries=_HITS_BUCKETS,
        )
        # Track current semaphore occupancy as a running counter delta
        self._inflight_count = 0

    def record_qa_start(self) -> None:
        self._inflight_count += 1
        self.qa_inflight.set(self._inflight_count)

    def record_qa_end(
        self,
        total_ms: float,
        fallback_reason: str | None,
        error: bool = False,
    ) -> None:
        self._inflight_count = max(0, self._inflight_count - 1)
        self.qa_inflight.set(self._inflight_count)
        if error:
            self.qa_requests.inc(tags={"status": "error"})
            return
        self.qa_latency.observe(total_ms)
        if fallback_reason:
            self.qa_requests.inc(tags={"status": "fallback"})
            self.qa_fallbacks.inc(tags={"reason": fallback_reason})
        else:
            self.qa_requests.inc(tags={"status": "ok"})

    def record_step(self, step: str, ms: float) -> None:
        self.qa_step_latency.observe(ms, tags={"step": step})

    def record_retrieval(
        self,
        top_score: float | None,
        hits_raw: int,
        hits_selected: int,
    ) -> None:
        if top_score is not None:
            self.qa_retrieval_top_score.observe(float(top_score))
        self.qa_retrieval_hits_raw.observe(float(hits_raw))
        self.qa_retrieval_hits_selected.observe(float(hits_selected))

    def record_ttft(self, ttft_ms: float) -> None:
        self.qa_ttft_ms.observe(float(ttft_ms))

    def record_completion_tokens(self, completion_tokens: int) -> None:
        # Always observe, including 0 — empty-answer cases are diagnostic.
        self.qa_completion_tokens.observe(float(completion_tokens))
