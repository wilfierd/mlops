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
_DEFAULT_SYSTEM_PROMPT = (
    "Bạn là trợ lý AI. Luôn trả lời bằng tiếng Việt tự nhiên, ngắn gọn. "
    "Không hiển thị suy luận nội bộ. /no_think"
)


def _env_int(name: str, default: int) -> int:
    """Tolerant int parse: accepts "1.5" -> 1 (floor), not just whole numbers.

    Needed because Terraform may pass `replica_cpus=1.5` as env value but
    n_threads must be a real OS thread count integer.
    """
    raw = os.getenv(name)
    if not raw:
        return default
    try:
        return int(raw)
    except ValueError:
        return int(float(raw))


def _env_bool(name: str, default: bool) -> bool:
    raw = os.getenv(name)
    if raw is None:
        return default
    return raw.lower() in {"1", "true", "yes", "on"}


def _strip_thinking(text: str) -> str:
    text = _THINK_RE.sub("", text).strip()
    stripped = text.lstrip()
    if stripped.startswith("<think>"):
        if "</think>" in stripped:
            return stripped.split("</think>", 1)[1].strip()
        return ""
    if "</think>" in stripped:
        return stripped.split("</think>", 1)[1].strip()
    return text


def _chatml_escape(content: str) -> str:
    # Avoid users injecting ChatML turn delimiters into the formatted prompt.
    return content.replace("<|im_start|>", "").replace("<|im_end|>", "")


def _build_chatml_prompt(messages: list[Message], enable_thinking: bool) -> str:
    normalized = [{"role": m.role, "content": m.content} for m in messages]

    if normalized and normalized[0]["role"] == "system":
        normalized[0] = {
            "role": "system",
            "content": f"{normalized[0]['content'].strip()}\n\n{_DEFAULT_SYSTEM_PROMPT}",
        }
    else:
        normalized.insert(0, {"role": "system", "content": _DEFAULT_SYSTEM_PROMPT})

    if not enable_thinking:
        for message in reversed(normalized):
            if message["role"] == "user":
                message["content"] = f"{message['content'].rstrip()}\n/no_think"
                break

    prompt = ""
    for message in normalized:
        role = message["role"]
        content = _chatml_escape(message["content"])
        prompt += f"<|im_start|>{role}\n{content}<|im_end|>\n"

    prompt += "<|im_start|>assistant\n"
    if not enable_thinking:
        prompt += "<think>\n\n</think>\n\n"
    return prompt


class LlamaCppBackend:
    def __init__(self) -> None:
        from huggingface_hub import hf_hub_download
        from llama_cpp import Llama

        gguf_repo = os.getenv("GGUF_REPO_ID", "bartowski/Qwen_Qwen3-0.6B-GGUF")
        gguf_filename = os.getenv("GGUF_FILENAME", "Qwen_Qwen3-0.6B-Q4_K_M.gguf")

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

        self.llm = Llama(
            model_path=model_path,
            n_ctx=n_ctx,
            n_threads=n_threads,
            n_batch=n_batch,
            verbose=False,
        )

    def generate(
        self,
        messages: list[Message],
        max_new_tokens: int,
        temperature: float,
        top_p: float,
    ) -> str:
        # Qwen3 disables thinking via a chat-template flag, but the
        # llama-cpp-python API in use here does not expose chat_template_kwargs.
        # Format ChatML ourselves and inject Qwen's non-thinking prefill.
        prompt = _build_chatml_prompt(messages, self.enable_thinking)
        result = self.llm(
            prompt,
            temperature=max(temperature, 0.0),
            top_p=top_p,
            max_tokens=max_new_tokens,
            stop=["<|im_end|>", "<|endoftext|>"],
            echo=False,
        )
        text = (result["choices"][0]["text"] or "").strip()

        if not self.enable_thinking:
            text = _strip_thinking(text)

        return text or "(empty response)"
