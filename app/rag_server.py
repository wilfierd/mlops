from __future__ import annotations

import asyncio
import hashlib
import json
import os
import time
from typing import Any, Literal

import boto3
import botocore.exceptions
import numpy as np
import tiktoken
from pathlib import Path

from fastapi import FastAPI, File, HTTPException, Response, UploadFile
from fastapi.responses import HTMLResponse
from fastapi.staticfiles import StaticFiles
from openai import AsyncOpenAI
from pydantic import BaseModel, Field
from qdrant_client import models as qm
from ray import serve
from ray.serve.handle import DeploymentHandle

from app.embedder import E5OnnxEmbedder
from app.metrics import RagMetrics
from app.ingest import (
    ALLOWED_MIMES,
    EXT_TO_MIME,
    QDRANT_COLLECTION,
    _qdrant,
    detect_mime,
    ingest_task,
    meta_read,
    meta_write,
    raw_key,
    reap_stuck,
)

api = FastAPI(title="RAG App")
api.mount(
    "/static",
    StaticFiles(directory=Path(__file__).parent / "static"),
    name="static",
)

MAX_UPLOAD_BYTES = int(os.environ.get("MAX_UPLOAD_BYTES", str(50 * 1024 * 1024)))
S3_BUCKET = os.environ.get("S3_BUCKET", "")
REAPER_INTERVAL_S = 300
VLLM_BASE_URL = os.environ.get(
    "VLLM_BASE_URL",
    "http://vllm-server-0.vllm-server.llm-chat.svc.cluster.local:8000/v1",
)
VLLM_MAX_MODEL_LEN = int(os.environ.get("VLLM_MAX_MODEL_LEN", "4096"))
QA_INFLIGHT = asyncio.Semaphore(16)
_TIMEOUTS: dict[str, float] = {"embed": 2.0, "qdrant": 2.0, "vllm": 60.0}

_RAG_SYSTEM = (
    "Bạn là trợ lý trả lời câu hỏi dựa trên các đoạn tài liệu cho trước.\n"
    "Quy tắc bắt buộc:\n"
    "1. CHỈ trả lời dựa trên nội dung trong CONTEXT phía dưới.\n"
    "2. Nếu CONTEXT không đủ thông tin để trả lời chính xác, trả lời CHÍNH XÁC chuỗi: "
    '"Tôi không tìm thấy thông tin trong tài liệu."\n'
    "3. Sau mỗi khẳng định, thêm tham chiếu dạng [Nguồn N] tương ứng với đoạn nguồn.\n"
    "4. Trả lời ngắn gọn, không bịa số liệu, không suy diễn.\n"
    "5. Trả lời bằng cùng ngôn ngữ với câu hỏi."
)
_RAG_PROMPT_TEMPLATE = "CONTEXT:\n{context}\n\nCÂU HỎI: {question}\n\nTRẢ LỜI:"

_ENC: tiktoken.Encoding | None = None


def _get_enc() -> tiktoken.Encoding:
    global _ENC
    if _ENC is None:
        _ENC = tiktoken.get_encoding("cl100k_base")
    return _ENC


def _count_tokens(text: str) -> int:
    return len(_get_enc().encode(text))


def _trim_to_budget(text: str, max_tokens: int) -> str:
    enc = _get_enc()
    tokens = enc.encode(text)
    if len(tokens) <= max_tokens:
        return text
    return enc.decode(tokens[:max_tokens])


_RAG_SYSTEM_TOKENS: int | None = None


def _context_budget(question_tokens: int) -> int:
    """Max context tokens that fit in vLLM's context window given the question length."""
    global _RAG_SYSTEM_TOKENS
    if _RAG_SYSTEM_TOKENS is None:
        _RAG_SYSTEM_TOKENS = _count_tokens(_RAG_SYSTEM)
    # 15 ≈ template scaffolding; 30 = safety margin for tokenizer edge cases
    budget = VLLM_MAX_MODEL_LEN - _RAG_SYSTEM_TOKENS - question_tokens - 400 - 15 - 30
    return max(budget, 500)


def _mmr_rerank(
    query_vec: list[float],
    candidates: list[Any],
    k: int,
    lambda_: float = 0.5,
) -> list[Any]:
    """Maximal Marginal Relevance: diversify top-k from Qdrant candidates."""
    if not candidates or k <= 0:
        return []
    selected: list[Any] = []
    remaining = list(candidates)
    while remaining and len(selected) < k:
        if not selected:
            best = max(remaining, key=lambda c: c.score)
        else:
            sel_norms = [
                sv / (np.linalg.norm(sv) + 1e-9)
                for s in selected
                if s.vector is not None
                for sv in [np.asarray(s.vector, dtype=np.float32)]
            ]

            def _score(c: Any, _sn: list[Any] = sel_norms) -> float:
                if c.vector is None or not _sn:
                    return lambda_ * c.score
                cv = np.asarray(c.vector, dtype=np.float32)
                cv_n = cv / (np.linalg.norm(cv) + 1e-9)
                max_sim = max(float(np.dot(cv_n, sn)) for sn in _sn)
                return lambda_ * c.score - (1 - lambda_) * max_sim

            best = max(remaining, key=_score)
        selected.append(best)
        remaining.remove(best)
    return selected


def _env_int(name: str, default: int) -> int:
    raw = os.getenv(name)
    return int(raw) if raw else default


def _env_float(name: str, default: float) -> float:
    raw = os.getenv(name)
    return float(raw) if raw else default


# ── Models ────────────────────────────────────────────────────────────────────

class EmbedRequest(BaseModel):
    texts: list[str] = Field(min_length=1, max_length=64)
    input_type: Literal["query", "passage", "raw"] = "query"


class EmbedResponse(BaseModel):
    vectors: list[list[float]]
    dim: int
    count: int
    model: str
    input_type: str
    elapsed_ms: float
    replica: str


class DocStatus(BaseModel):
    doc_id: str
    status: str
    filename: str | None = None
    num_chunks: int | None = None
    error_code: str | None = None
    uploaded_at: str | None = None
    completed_at: str | None = None


class QARequest(BaseModel):
    question: str
    doc_ids: list[str] | None = None
    top_k: int = Field(default=5, ge=1, le=10)
    score_threshold: float = Field(default=0.5, ge=0.0, le=1.0)


class SourceRef(BaseModel):
    doc_id: str
    doc_title: str | None = None
    chunk_idx: int
    score: float
    text: str


class QAResponse(BaseModel):
    answer: str
    sources: list[SourceRef]
    latency_ms: dict[str, float]
    fallback_reason: str | None = None


# ── Embedder ─────────────────────────────────────────────────────────────────

@serve.deployment(
    name="Embedder",
    num_replicas=1,
    max_ongoing_requests=_env_int("EMBEDDER_MAX_ONGOING_REQUESTS", 8),
    ray_actor_options={"num_cpus": _env_float("EMBEDDER_NUM_CPUS", 0.5)},
)
class Embedder:
    def __init__(self) -> None:
        self.replica = f"{os.uname().nodename}:{os.getpid()}"
        self.backend = E5OnnxEmbedder()

    # Sync — Ray Serve runs this in a thread pool (correct for CPU-bound ONNX inference).
    def embed(self, texts: list[str], input_type: str) -> EmbedResponse:
        vectors, elapsed_ms = self.backend.embed(texts, input_type)  # type: ignore[arg-type]
        return EmbedResponse(
            vectors=vectors,
            dim=self.backend.dim,
            count=len(vectors),
            model=self.backend.model_id,
            input_type=input_type,
            elapsed_ms=elapsed_ms,
            replica=self.replica,
        )


# ── RagApi ────────────────────────────────────────────────────────────────────

@serve.deployment(
    name="RagApi",
    num_replicas=1,
    max_ongoing_requests=_env_int("RAG_API_MAX_ONGOING_REQUESTS", 32),
    ray_actor_options={"num_cpus": _env_float("RAG_API_NUM_CPUS", 0.2)},
)
@serve.ingress(api)
class RagApi:
    def __init__(self, embedder: DeploymentHandle) -> None:
        self.embedder = embedder
        self.s3 = boto3.client("s3")
        self._vllm = AsyncOpenAI(base_url=VLLM_BASE_URL, api_key="not-needed")
        self._m = RagMetrics()
        self._reaper_bg = asyncio.get_event_loop().create_task(self._reaper_loop())

    async def _reaper_loop(self) -> None:
        while True:
            await asyncio.sleep(REAPER_INTERVAL_S)
            if not S3_BUCKET:
                continue
            try:
                n = await reap_stuck(S3_BUCKET)
                if n:
                    import logging
                    logging.getLogger(__name__).info("reaper cleaned %d stuck docs", n)
            except Exception:
                import logging
                logging.getLogger(__name__).exception("reaper error")

    # ── UI ───────────────────────────────────────────────────────────────────

    @api.get("/", response_class=HTMLResponse)
    async def ui_home(self) -> HTMLResponse:
        html = (Path(__file__).parent / "templates" / "index.html").read_text()
        return HTMLResponse(html)

    # ── Health ──────────────────────────────────────────────────────────────

    @api.get("/healthz")
    async def healthz(self) -> dict[str, str]:
        try:
            await asyncio.wait_for(
                self.embedder.embed.remote(["ping"], "raw"),
                timeout=2.0,
            )
        except Exception as exc:
            raise HTTPException(status_code=503, detail=f"embedder not ready: {type(exc).__name__}")
        return {"status": "ok"}

    # ── Embed ────────────────────────────────────────────────────────────────

    @api.post("/embed", response_model=EmbedResponse)
    async def embed(self, request: EmbedRequest) -> EmbedResponse:
        if any(not text.strip() for text in request.texts):
            raise HTTPException(status_code=400, detail="texts must not contain empty strings")
        return await self.embedder.embed.remote(request.texts, request.input_type)

    # ── Ingest: POST /documents ──────────────────────────────────────────────

    @api.post("/documents", status_code=202)
    async def upload_document(self, file: UploadFile = File(...)) -> dict:
        if not S3_BUCKET:
            raise HTTPException(status_code=503, detail="S3_BUCKET not configured")

        data = await file.read()

        # [1] Validate size
        if len(data) > MAX_UPLOAD_BYTES:
            raise HTTPException(status_code=413, detail="oversized_doc: file exceeds 50 MiB limit")

        # [1] Validate MIME via magic bytes
        mime = detect_mime(data)
        if not mime or mime not in ALLOWED_MIMES:
            raise HTTPException(
                status_code=415,
                detail=f"unsupported_mime: {mime!r}. Allowed: pdf, txt, md, docx",
            )

        # [1] PDF page limit
        if mime == "application/pdf":
            try:
                import pypdf
                reader = pypdf.PdfReader(__import__("io").BytesIO(data))
                if len(reader.pages) > 500:
                    raise HTTPException(status_code=413, detail="oversized_doc: PDF exceeds 500 pages")
            except HTTPException:
                raise
            except Exception:
                pass  # parse errors caught later in ingest_task

        # [2] doc_id = first 16 hex chars of SHA-256
        doc_id = hashlib.sha256(data).hexdigest()[:16]

        # Determine file extension from MIME
        ext_map = {v: k for k, v in EXT_TO_MIME.items()}
        ext = ext_map.get(mime, "txt")
        filename = file.filename or f"{doc_id}.{ext}"

        # [3] Check existing meta
        meta = meta_read(self.s3, S3_BUCKET, doc_id)
        if meta:
            status = meta.get("status")
            if status == "ready":
                self._m.ingest_docs.inc(tags={"result": "already_ready"})
                return {"doc_id": doc_id, "status": "ready", "num_chunks": meta.get("num_chunks")}
            if status == "processing":
                self._m.ingest_docs.inc(tags={"result": "already_processing"})
                return {"doc_id": doc_id, "status": "processing"}
            # failed or deleted → falls through to retry path

        # [4] Upload raw to S3 (content-addressed; concurrent uploads of same file are safe)
        self.s3.put_object(
            Bucket=S3_BUCKET,
            Key=raw_key(doc_id, ext),
            Body=data,
            ContentType=mime,
        )

        # [5] Write uploaded meta
        meta_write(self.s3, S3_BUCKET, doc_id, {
            "doc_id": doc_id,
            "status": "uploaded",
            "sha256": hashlib.sha256(data).hexdigest(),
            "mime": mime,
            "size_bytes": len(data),
            "filename": filename,
            "uploaded_at": __import__("datetime").datetime.now(__import__("datetime").timezone.utc).isoformat(),
        })

        # [6] Submit Ray Task (fire-and-forget; meta tracks progress)
        ingest_task.remote(doc_id, ext, filename, S3_BUCKET)
        self._m.ingest_docs.inc(tags={"result": "accepted"})

        # [7] Return 202 Accepted
        return {"doc_id": doc_id, "status": "processing"}

    # ── Ingest: GET /documents ───────────────────────────────────────────────

    @api.get("/documents", response_model=list[DocStatus])
    async def list_documents(self) -> list[DocStatus]:
        if not S3_BUCKET:
            raise HTTPException(status_code=503, detail="S3_BUCKET not configured")
        docs: list[DocStatus] = []
        paginator = self.s3.get_paginator("list_objects_v2")
        for page in paginator.paginate(Bucket=S3_BUCKET, Prefix="meta/"):
            for obj in page.get("Contents", []):
                try:
                    raw = self.s3.get_object(Bucket=S3_BUCKET, Key=obj["Key"])
                    meta = json.loads(raw["Body"].read())
                    if meta.get("status") == "deleted":
                        continue
                    docs.append(DocStatus(
                        doc_id=meta.get("doc_id", ""),
                        status=meta.get("status", "unknown"),
                        filename=meta.get("filename"),
                        num_chunks=meta.get("num_chunks"),
                        error_code=meta.get("error_code"),
                        uploaded_at=meta.get("uploaded_at"),
                        completed_at=meta.get("completed_at"),
                    ))
                except Exception:
                    continue
        return docs

    # ── Ingest: GET /documents/{doc_id} ─────────────────────────────────────

    @api.get("/documents/{doc_id}", response_model=DocStatus)
    async def get_document(self, doc_id: str) -> DocStatus:
        if not S3_BUCKET:
            raise HTTPException(status_code=503, detail="S3_BUCKET not configured")
        meta = meta_read(self.s3, S3_BUCKET, doc_id)
        if not meta or meta.get("status") == "deleted":
            raise HTTPException(status_code=404, detail="document not found")
        return DocStatus(
            doc_id=doc_id,
            status=meta.get("status", "unknown"),
            filename=meta.get("filename"),
            num_chunks=meta.get("num_chunks"),
            error_code=meta.get("error_code"),
            uploaded_at=meta.get("uploaded_at"),
            completed_at=meta.get("completed_at"),
        )

    # ── Ingest: DELETE /documents/{doc_id} ──────────────────────────────────

    @api.delete("/documents/{doc_id}", status_code=204)
    async def delete_document(self, doc_id: str) -> Response:
        if not S3_BUCKET:
            raise HTTPException(status_code=503, detail="S3_BUCKET not configured")
        meta = meta_read(self.s3, S3_BUCKET, doc_id)
        if not meta or meta.get("status") == "deleted":
            raise HTTPException(status_code=404, detail="document not found")

        # Delete Qdrant vectors FIRST — if this fails, we leave meta intact
        # so the doc is still accessible and the user can retry.
        try:
            _qdrant().delete(
                collection_name=QDRANT_COLLECTION,
                points_selector=qm.FilterSelector(
                    filter=qm.Filter(must=[qm.FieldCondition(key="doc_id", match=qm.MatchValue(value=doc_id))])
                ),
            )
        except Exception as exc:
            raise HTTPException(status_code=503, detail=f"qdrant delete failed: {type(exc).__name__}") from exc
        # Vectors removed — now soft-delete the meta record.
        meta_write(self.s3, S3_BUCKET, doc_id, {"status": "deleted"})
        return Response(status_code=204)

    # ── QA: POST /qa ─────────────────────────────────────────────────────────

    @api.post("/qa", response_model=QAResponse)
    async def query(self, request: QARequest) -> QAResponse:
        if not S3_BUCKET:
            raise HTTPException(status_code=503, detail="S3_BUCKET not configured")

        # [0] Backpressure — non-blocking acquire with 100ms grace
        try:
            await asyncio.wait_for(QA_INFLIGHT.acquire(), timeout=0.1)
        except asyncio.TimeoutError:
            self._m.qa_fallbacks.inc(tags={"reason": "backpressure"})
            self._m.qa_requests.inc(tags={"status": "fallback"})
            raise HTTPException(
                status_code=429,
                detail={"error": "busy_try_again", "fallback_reason": "backpressure"},
            )

        t_start = time.monotonic()
        latency: dict[str, float] = {}
        self._m.record_qa_start()
        _fallback_reason: str | None = None
        _is_error = False
        try:
            # [1] Validate question
            q = request.question.strip()
            if len(q) <= 3:
                _is_error = True
                raise HTTPException(status_code=400, detail="question_too_short")
            q_tok = _count_tokens(q)
            if q_tok > 500:
                _is_error = True
                raise HTTPException(status_code=400, detail="question_too_long")

            # [2] Verify each requested doc_id is ready
            if request.doc_ids:
                for did in request.doc_ids:
                    meta = await asyncio.to_thread(meta_read, self.s3, S3_BUCKET, did)
                    if not meta or meta.get("status") != "ready":
                        _is_error = True
                        raise HTTPException(status_code=400, detail=f"doc_not_ready: {did}")

            # [3] Embed query with "query: " prefix required by e5 model
            t0 = time.monotonic()
            try:
                embed_resp = await asyncio.wait_for(
                    self.embedder.embed.remote([f"query: {q}"], "raw"),
                    timeout=_TIMEOUTS["embed"],
                )
            except asyncio.TimeoutError:
                _fallback_reason = "embed_timeout"
                return QAResponse(
                    answer="", sources=[], latency_ms=latency, fallback_reason=_fallback_reason
                )
            latency["embed"] = round((time.monotonic() - t0) * 1000, 1)
            self._m.record_step("embed", latency["embed"])
            query_vec: list[float] = embed_resp.vectors[0]

            # [4] Qdrant search top-20 (pull wider for MMR diversification)
            t0 = time.monotonic()
            q_filter = None
            if request.doc_ids:
                q_filter = qm.Filter(
                    must=[qm.FieldCondition(key="doc_id", match=qm.MatchAny(any=request.doc_ids))]
                )
            try:
                hits_raw = await asyncio.wait_for(
                    asyncio.to_thread(
                        lambda: _qdrant().query_points(
                            collection_name=QDRANT_COLLECTION,
                            query=query_vec,
                            query_filter=q_filter,
                            limit=20,
                            score_threshold=request.score_threshold,
                            with_vectors=True,
                        ).points
                    ),
                    timeout=_TIMEOUTS["qdrant"],
                )
            except asyncio.TimeoutError:
                _fallback_reason = "qdrant_timeout"
                return QAResponse(
                    answer="", sources=[], latency_ms=latency, fallback_reason=_fallback_reason
                )
            except Exception:
                _is_error = True
                raise HTTPException(status_code=503, detail="qdrant unavailable")
            latency["qdrant"] = round((time.monotonic() - t0) * 1000, 1)
            self._m.record_step("qdrant", latency["qdrant"])

            # [5] No relevant hits (all below score_threshold or collection empty)
            if not hits_raw:
                _fallback_reason = "no_hits"
                return QAResponse(
                    answer="Tôi không tìm thấy thông tin trong tài liệu.",
                    sources=[],
                    latency_ms=latency,
                    fallback_reason=_fallback_reason,
                )

            # [6] MMR rerank → top_k diverse results
            t0 = time.monotonic()
            hits = _mmr_rerank(query_vec, hits_raw, k=request.top_k, lambda_=0.5)
            latency["mmr"] = round((time.monotonic() - t0) * 1000, 1)
            self._m.record_step("mmr", latency["mmr"])

            # [7] Build context with source attribution headers
            context_parts = [
                f"[Nguồn {i+1}: {h.payload.get('doc_title', h.payload.get('doc_id', ''))}, "
                f"đoạn {h.payload.get('chunk_idx', i)}]\n{h.payload.get('text', '')}"
                for i, h in enumerate(hits)
            ]
            context = "\n\n".join(context_parts)

            # [8] Trim to dynamic budget: max_model_len − system − question − output − margin
            context = _trim_to_budget(context, _context_budget(q_tok))
            prompt = _RAG_PROMPT_TEMPLATE.format(context=context, question=q)

            # [9] Call vLLM (OpenAI-compatible endpoint)
            t0 = time.monotonic()
            try:
                resp = await asyncio.wait_for(
                    self._vllm.chat.completions.create(
                        model="qwen-rag",
                        messages=[
                            {"role": "system", "content": _RAG_SYSTEM},
                            {"role": "user", "content": prompt},
                        ],
                        temperature=0.2,
                        top_p=0.85,
                        max_tokens=400,
                        frequency_penalty=0.05,
                        stop=["<|im_end|>", "<|endoftext|>", "\n\nCÂU HỎI:"],
                    ),
                    timeout=_TIMEOUTS["vllm"],
                )
            except asyncio.TimeoutError:
                _fallback_reason = "llm_timeout"
                return QAResponse(
                    answer="", sources=[], latency_ms=latency, fallback_reason=_fallback_reason
                )
            except Exception:
                _is_error = True
                raise HTTPException(status_code=503, detail="llm unavailable")
            latency["llm"] = round((time.monotonic() - t0) * 1000, 1)
            self._m.record_step("llm", latency["llm"])
            latency["total"] = round((time.monotonic() - t_start) * 1000, 1)

            answer = resp.choices[0].message.content or ""
            sources = [
                SourceRef(
                    doc_id=h.payload.get("doc_id", ""),
                    doc_title=h.payload.get("doc_title"),
                    chunk_idx=int(h.payload.get("chunk_idx", 0)),
                    score=round(h.score, 4),
                    text=h.payload.get("text", ""),
                )
                for h in hits
            ]

            # [10] Return answer with sources and per-step latency breakdown
            return QAResponse(answer=answer, sources=sources, latency_ms=latency)

        finally:
            QA_INFLIGHT.release()
            total_ms = round((time.monotonic() - t_start) * 1000, 1)
            self._m.record_qa_end(total_ms, _fallback_reason, error=_is_error)


rag_app = RagApi.bind(Embedder.bind())  # type: ignore[attr-defined]
