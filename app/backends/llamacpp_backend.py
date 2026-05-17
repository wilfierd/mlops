"""llama.cpp backend — Q4_K_M GGUF on CPU, ARM-NEON optimized.

Loads a GGUF file from the local HF cache (downloaded at image build time
when `PRELOAD_MODEL=true`, or on first request otherwise). Generation goes
through `llama.cpp` directly via `llama-cpp-python` bindings — much faster
than HF Transformers on CPU for small models.
"""
from __future__ import annotations

import os
import re
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from .base import Message

_THINK_RE = re.compile(r"<think>.*?</think>", re.DOTALL)


def _env_int(name: str, default: int) -> int:
    raw = os.getenv(name)
    return int(raw) if raw else default


def _env_bool(name: str, default: bool) -> bool:
    raw = os.getenv(name)
    if raw is None:
        return default
    return raw.lower() in {"1", "true", "yes", "on"}


class LlamaCppBackend:
    def __init__(self) -> None:
        from huggingface_hub import hf_hub_download
        from llama_cpp import Llama

        gguf_repo = os.getenv("GGUF_REPO_ID", "Qwen/Qwen3-0.6B-GGUF")
        gguf_filename = os.getenv("GGUF_FILENAME", "Qwen3-0.6B-Q4_K_M.gguf")

        # Display name preserved in /health + ChatResponse.model so
        # benchmark logs can tell which backend produced an answer.
        self.model_id = f"{gguf_repo}/{gguf_filename}"
        self.enable_thinking = _env_bool("ENABLE_THINKING", False)

        # llama.cpp tuning knobs
        n_ctx = _env_int("LLAMA_N_CTX", 2048)
        n_threads = _env_int("LLAMA_N_THREADS", max(1, os.cpu_count() or 1))
        n_batch = _env_int("LLAMA_N_BATCH", 128)

        # hf_hub_download caches under HF_HOME so subsequent loads are free.
        # The Dockerfile pre-downloads when PRELOAD_MODEL=true so cold start
        # is just an mmap.
        model_path = hf_hub_download(repo_id=gguf_repo, filename=gguf_filename)

        # `chat_format` controls how messages -> prompt string. Qwen and
        # most modern instruct models use ChatML. llama.cpp auto-detects
        # from GGUF metadata when chat_format=None, but pin to "chatml" for
        # determinism across model swaps.
        self.llm = Llama(
            model_path=model_path,
            n_ctx=n_ctx,
            n_threads=n_threads,
            n_batch=n_batch,
            chat_format=os.getenv("LLAMA_CHAT_FORMAT", "chatml"),
            verbose=False,
        )

    def generate(
        self,
        messages: list[Message],
        max_new_tokens: int,
        temperature: float,
        top_p: float,
    ) -> str:
        # llama-cpp-python wants plain dicts.
        payload = [{"role": m.role, "content": m.content} for m in messages]

        result = self.llm.create_chat_completion(
            messages=payload,
            temperature=max(temperature, 0.0),
            top_p=top_p,
            max_tokens=max_new_tokens,
        )
        text = (result["choices"][0]["message"]["content"] or "").strip()

        if not self.enable_thinking:
            text = _THINK_RE.sub("", text).strip()
            stripped = text.lstrip()
            if stripped.startswith("<think>") and "</think>" in stripped:
                text = stripped.split("</think>", 1)[1].strip()

        return text or "(empty response)"
