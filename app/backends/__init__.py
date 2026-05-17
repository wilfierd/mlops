"""Inference backend selection.

The Ray Serve replica picks the backend at startup via env var
`INFERENCE_BACKEND` (default `llamacpp`). Each backend is an independent class
that implements `BackendProtocol`. Adding a new backend (e.g. vllm) means
adding a new file under this package and one entry in `get_backend()`.
"""
from __future__ import annotations

import os

from .base import BackendProtocol


def get_backend() -> BackendProtocol:
    name = os.getenv("INFERENCE_BACKEND", "llamacpp").lower()
    if name == "llamacpp":
        from .llamacpp_backend import LlamaCppBackend

        return LlamaCppBackend()
    if name in {"transformers", "hf"}:
        from .transformers_backend import TransformersBackend

        return TransformersBackend()
    raise ValueError(
        f"Unknown INFERENCE_BACKEND={name!r}. Supported: llamacpp, transformers."
    )


__all__ = ["BackendProtocol", "get_backend"]
