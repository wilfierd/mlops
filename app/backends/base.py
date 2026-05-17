"""Backend protocol — every backend must satisfy this shape.

`generate` is a *blocking* call; the Ray Serve replica wraps it in
`asyncio.to_thread` so the proxy event loop isn't stalled by CPU-bound
inference.
"""
from __future__ import annotations

from typing import Protocol, runtime_checkable

from pydantic import BaseModel


class Message(BaseModel):
    """Re-exported for backend isolation; mirrors app.server.Message."""

    role: str
    content: str


@runtime_checkable
class BackendProtocol(Protocol):
    """Concrete name shown in `/health` + `ChatResponse.model`."""

    model_id: str

    def generate(
        self,
        messages: list[Message],
        max_new_tokens: int,
        temperature: float,
        top_p: float,
    ) -> str:
        """Return the assistant's reply text (no role markers, no <think> blocks)."""
        ...
