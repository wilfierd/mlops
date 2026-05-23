from __future__ import annotations

import asyncio
import os
from typing import Literal

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field
from ray import serve
from ray.serve.handle import DeploymentHandle

from app.embedder import E5OnnxEmbedder


api = FastAPI(title="RAG App")


def _env_int(name: str, default: int) -> int:
    raw = os.getenv(name)
    if not raw:
        return default
    return int(raw)


def _env_float(name: str, default: float) -> float:
    raw = os.getenv(name)
    if not raw:
        return default
    return float(raw)


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

    # Sync method — Ray Serve runs it in a thread pool automatically, which is
    # correct for CPU-bound ONNX inference. Using async here would block the
    # actor's event loop for the duration of inference.
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

    @api.post("/embed", response_model=EmbedResponse)
    async def embed(self, request: EmbedRequest) -> EmbedResponse:
        if any(not text.strip() for text in request.texts):
            raise HTTPException(status_code=400, detail="texts must not contain empty strings")
        return await self.embedder.embed.remote(request.texts, request.input_type)

    # P6: POST /documents, GET /documents, DELETE /documents/{id}  (ingest pipeline)
    # P6: POST /qa  (embed → qdrant search → vllm)


rag_app = RagApi.bind(Embedder.bind())  # type: ignore[attr-defined]
