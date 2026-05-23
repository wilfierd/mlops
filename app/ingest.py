"""
P5 ingest pipeline: S3 meta state machine + parse + chunk + embed + Qdrant upsert.

State machine:  uploaded → processing → ready
                                      ↘ failed  → (user retry) → processing
                uploaded → (DELETE)  → deleted
"""
from __future__ import annotations

import io
import json
import logging
import os
import time
import uuid
from datetime import datetime, timezone
from typing import Any

import boto3
import botocore.exceptions
import chardet
import filetype
import ray
import tiktoken
from langchain_text_splitters import RecursiveCharacterTextSplitter
from qdrant_client import QdrantClient
from qdrant_client import models as qm

log = logging.getLogger(__name__)

# ── env ────────────────────────────────────────────────────────────────────────
S3_PREFIX_DOCS = os.environ.get("S3_PREFIX_DOCS", "docs/")
QDRANT_HOST = os.environ.get("QDRANT_HOST", "qdrant-0.qdrant.llm-chat.svc.cluster.local")
QDRANT_GRPC_PORT = int(os.environ.get("QDRANT_GRPC_PORT", "6334"))
QDRANT_COLLECTION = os.environ.get("QDRANT_COLLECTION", "documents")
CHUNK_SIZE = int(os.environ.get("CHUNK_SIZE_TOKENS", "500"))
CHUNK_OVERLAP = int(os.environ.get("CHUNK_OVERLAP_TOKENS", "80"))
INGEST_BATCH_SIZE = int(os.environ.get("INGEST_BATCH_SIZE", "32"))
STUCK_TIMEOUT_MIN = 10

ALLOWED_MIMES = {
    "application/pdf",
    "text/plain",
    "text/markdown",
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
}
EXT_TO_MIME = {
    "pdf": "application/pdf",
    "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    "md": "text/markdown",
    "txt": "text/plain",
}


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def meta_key(doc_id: str) -> str:
    return f"meta/{doc_id}.json"


def raw_key(doc_id: str, ext: str) -> str:
    return f"{S3_PREFIX_DOCS}{doc_id}.{ext}"


def meta_read(s3, bucket: str, doc_id: str) -> dict[str, Any] | None:
    try:
        obj = s3.get_object(Bucket=bucket, Key=meta_key(doc_id))
        return json.loads(obj["Body"].read())
    except botocore.exceptions.ClientError as e:
        if e.response["Error"]["Code"] in ("NoSuchKey", "404"):
            return None
        raise


def meta_write(s3, bucket: str, doc_id: str, patch: dict[str, Any]) -> None:
    existing = meta_read(s3, bucket, doc_id) or {}
    existing.update(patch)
    s3.put_object(
        Bucket=bucket,
        Key=meta_key(doc_id),
        Body=json.dumps(existing).encode(),
        ContentType="application/json",
    )


def detect_mime(data: bytes) -> str | None:
    kind = filetype.guess(data[:512])
    if kind:
        return kind.mime
    try:
        data[:512].decode("utf-8")
        return "text/plain"
    except UnicodeDecodeError:
        return None


def _parse_pdf(data: bytes) -> str:
    import pypdf
    reader = pypdf.PdfReader(io.BytesIO(data))
    return "\n".join(page.extract_text() or "" for page in reader.pages)


def _parse_docx(data: bytes) -> str:
    import docx
    doc = docx.Document(io.BytesIO(data))
    return "\n".join(p.text for p in doc.paragraphs if p.text.strip())


def _parse_text(data: bytes) -> str:
    result = chardet.detect(data[:8192])
    enc = result.get("encoding") or "utf-8"
    if (result.get("confidence") or 0) < 0.7:
        enc = "utf-8"
    return data.decode(enc, errors="replace")


def parse_doc(data: bytes, mime: str) -> str:
    if mime == "application/pdf":
        return _parse_pdf(data)
    if mime == "application/vnd.openxmlformats-officedocument.wordprocessingml.document":
        return _parse_docx(data)
    return _parse_text(data)


def chunk_text(text: str) -> list[str]:
    enc = tiktoken.get_encoding("cl100k_base")
    splitter = RecursiveCharacterTextSplitter(
        chunk_size=CHUNK_SIZE,
        chunk_overlap=CHUNK_OVERLAP,
        length_function=lambda s: len(enc.encode(s)),
        separators=["\n\n## ", "\n\n# ", "\n\n", "\n", ". ", "? ", "! ", "; ", ", ", " ", ""],
    )
    return splitter.split_text(text)


def _qdrant() -> QdrantClient:
    # timeout=5 caps blocking gRPC calls; prevents threads from hanging on network failure
    return QdrantClient(host=QDRANT_HOST, grpc_port=QDRANT_GRPC_PORT, prefer_grpc=True, timeout=5)


RAY_SERVE_APP_NAME = os.environ.get("RAY_SERVE_APP_NAME", "llm-chat")

# UUID v5 namespace for deterministic Qdrant point IDs.
_POINT_NS = uuid.UUID("6ba7b810-9dad-11d1-80b4-00c04fd430c8")  # uuid.NAMESPACE_URL


def point_id(doc_id: str, idx: int) -> str:
    """Deterministic UUID v5 from doc_id + chunk index — valid Qdrant string ID."""
    return str(uuid.uuid5(_POINT_NS, f"{doc_id}:{idx}"))


@ray.remote(num_cpus=0.2, max_retries=0)
async def ingest_task(doc_id: str, ext: str, filename: str, bucket: str) -> None:
    """
    Parse → chunk → embed → upsert Qdrant. Writes meta on every state transition.
    max_retries=0: state machine owns retry; auto-retry would re-enter processing
    without resetting meta, causing double-counting.
    """
    from ray import serve

    s3 = boto3.client("s3")
    qdrant = _qdrant()
    embedder = serve.get_deployment_handle("Embedder", app_name=RAY_SERVE_APP_NAME)

    try:
        meta_write(s3, bucket, doc_id, {"status": "processing", "started_at": _now()})

        # [a] Download
        obj = s3.get_object(Bucket=bucket, Key=raw_key(doc_id, ext))
        data = obj["Body"].read()

        # [b] Parse
        mime = EXT_TO_MIME.get(ext, "text/plain")
        text = parse_doc(data, mime)
        if len(text.strip()) < 100:
            meta_write(s3, bucket, doc_id, {
                "status": "failed",
                "error_code": "pdf_no_text_layer",
                "error_msg": "Extracted text < 100 chars — possibly a scanned PDF without text layer.",
                "failed_at": _now(),
            })
            return

        # [c] Chunk
        chunks = chunk_text(text)
        if not chunks:
            meta_write(s3, bucket, doc_id, {
                "status": "failed", "error_code": "empty_document", "failed_at": _now(),
            })
            return

        # [d] Delete any partial vectors from a previous failed run
        qdrant.delete(
            collection_name=QDRANT_COLLECTION,
            points_selector=qm.FilterSelector(
                filter=qm.Filter(must=[qm.FieldCondition(key="doc_id", match=qm.MatchValue(value=doc_id))])
            ),
        )

        # [e] Embed + upsert in batches of INGEST_BATCH_SIZE
        ingested_at = _now()
        for start in range(0, len(chunks), INGEST_BATCH_SIZE):
            batch = chunks[start : start + INGEST_BATCH_SIZE]
            passages = [f"passage: {c}" for c in batch]
            embed_resp = await embedder.embed.remote(passages, "raw")
            qdrant.upsert(
                collection_name=QDRANT_COLLECTION,
                points=[
                    qm.PointStruct(
                        id=point_id(doc_id, start + i),
                        vector=embed_resp.vectors[i],
                        payload={
                            "doc_id": doc_id,
                            "chunk_idx": start + i,
                            "text": batch[i],
                            "doc_title": filename,
                            "ingested_at": ingested_at,
                            "embedding_model": "e5-small-int8",
                        },
                    )
                    for i in range(len(batch))
                ],
            )

        # [f] Mark ready
        meta_write(s3, bucket, doc_id, {
            "status": "ready",
            "num_chunks": len(chunks),
            "completed_at": _now(),
            "embedding_model": "e5-small-int8",
        })
        log.info("ingest_task OK doc_id=%s chunks=%d", doc_id, len(chunks))

    except Exception as exc:
        log.exception("ingest_task FAILED doc_id=%s", doc_id)
        meta_write(s3, bucket, doc_id, {
            "status": "failed",
            "error_code": "ingest_error",
            "error_msg": str(exc)[:500],
            "failed_at": _now(),
        })


async def reap_stuck(bucket: str) -> int:
    """Scan S3 meta/ for docs stuck in 'processing' > STUCK_TIMEOUT_MIN. Mark failed + delete partial Qdrant vectors."""
    s3 = boto3.client("s3")
    qdrant = _qdrant()
    cutoff = time.time() - STUCK_TIMEOUT_MIN * 60
    reaped = 0

    paginator = s3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=bucket, Prefix="meta/"):
        for obj in page.get("Contents", []):
            try:
                raw = s3.get_object(Bucket=bucket, Key=obj["Key"])
                meta = json.loads(raw["Body"].read())
            except Exception:
                continue

            if meta.get("status") != "processing":
                continue
            started = meta.get("started_at", "")
            if not started:
                continue
            try:
                ts = datetime.fromisoformat(started).timestamp()
            except ValueError:
                continue
            if ts > cutoff:
                continue

            doc_id = obj["Key"].removeprefix("meta/").removesuffix(".json")
            try:
                meta_write(s3, bucket, doc_id, {
                    "status": "failed",
                    "error_code": "stuck_processing_timeout",
                    "failed_at": _now(),
                })
                qdrant.delete(
                    collection_name=QDRANT_COLLECTION,
                    points_selector=qm.FilterSelector(
                        filter=qm.Filter(must=[qm.FieldCondition(key="doc_id", match=qm.MatchValue(value=doc_id))])
                    ),
                )
                reaped += 1
                log.warning("reaper: marked doc_id=%s as failed (stuck_processing_timeout)", doc_id)
            except Exception:
                log.exception("reaper: error cleaning doc_id=%s", doc_id)

    return reaped
