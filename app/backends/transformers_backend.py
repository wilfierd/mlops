"""HuggingFace Transformers backend (rollback path).

Used for compatibility / regression compare. The default in this project is
`LlamaCppBackend`; flip via env `INFERENCE_BACKEND=transformers` to use this.
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


def _env_dtype(name: str, default: str):
    import torch

    raw = (os.getenv(name) or default).lower()
    return {
        "float32": torch.float32, "fp32": torch.float32,
        "bfloat16": torch.bfloat16, "bf16": torch.bfloat16,
        "float16": torch.float16, "fp16": torch.float16,
    }.get(raw, torch.float32)


class TransformersBackend:
    def __init__(self) -> None:
        import torch
        from transformers import AutoModelForCausalLM, AutoTokenizer

        self.model_id = os.getenv("MODEL_ID", "Qwen/Qwen3-0.6B")
        self.max_input_tokens = _env_int("MAX_INPUT_TOKENS", 2048)
        self.enable_thinking = _env_bool("ENABLE_THINKING", False)

        torch.set_num_threads(_env_int("TORCH_NUM_THREADS", max(1, os.cpu_count() or 1)))
        self._torch = torch
        self.tokenizer = AutoTokenizer.from_pretrained(self.model_id)
        self.model = AutoModelForCausalLM.from_pretrained(
            self.model_id,
            torch_dtype=_env_dtype("MODEL_DTYPE", "bfloat16"),
        )
        self.model.eval()
        if self.tokenizer.pad_token_id is None:
            self.tokenizer.pad_token = self.tokenizer.eos_token

    def _build_prompt(self, messages: list[Message]) -> str:
        normalized = [{"role": m.role, "content": m.content} for m in messages]
        chat_template = getattr(self.tokenizer, "chat_template", None)
        if chat_template:
            try:
                return self.tokenizer.apply_chat_template(
                    normalized,
                    tokenize=False,
                    add_generation_prompt=True,
                    enable_thinking=self.enable_thinking,
                )
            except TypeError:
                return self.tokenizer.apply_chat_template(
                    normalized, tokenize=False, add_generation_prompt=True,
                )
        return (
            "\n".join(f"{m['role'].upper()}: {m['content']}" for m in normalized)
            + "\nASSISTANT:"
        )

    def generate(
        self,
        messages: list[Message],
        max_new_tokens: int,
        temperature: float,
        top_p: float,
    ) -> str:
        prompt = self._build_prompt(messages)
        inputs = self.tokenizer(
            prompt,
            return_tensors="pt",
            truncation=True,
            max_length=self.max_input_tokens,
            return_attention_mask=True,
        )
        kwargs = {
            "input_ids": inputs["input_ids"],
            "attention_mask": inputs["attention_mask"],
            "max_new_tokens": max_new_tokens,
            "pad_token_id": self.tokenizer.pad_token_id,
            "eos_token_id": self.tokenizer.eos_token_id,
        }
        if temperature > 0:
            kwargs.update(do_sample=True, temperature=temperature, top_p=top_p)
        else:
            kwargs["do_sample"] = False

        with self._torch.inference_mode():
            out = self.model.generate(**kwargs)
        prompt_tokens = inputs["input_ids"].shape[-1]
        text = self.tokenizer.decode(out[0][prompt_tokens:], skip_special_tokens=True).strip()
        if not self.enable_thinking:
            text = _THINK_RE.sub("", text).strip()
            stripped = text.lstrip()
            if stripped.startswith("<think>") and "</think>" in stripped:
                text = stripped.split("</think>", 1)[1].strip()
        return text or "(empty response)"
