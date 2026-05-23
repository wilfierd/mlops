#!/usr/bin/env python3
"""
Smoke benchmark for the vllm-openai server (P2).

Drives /v1/chat/completions with a synthetic RAG-shaped prompt over the
OpenAI streaming protocol so we can break latency into:

  * TTFT (Time-To-First-Token) = prefill phase
        client_time(first chunk arrives) - client_time(request sent)
  * Decode duration             = total - TTFT
  * Prefill TPS (per request)   = prompt_tokens / TTFT
  * Decode TPS (per request)    = completion_tokens / decode_duration

Caveats:
  - Numbers are *client-side* and include network + httpx + SSE parser
    overhead. For point-in-time vLLM truth, scrape vllm:* /metrics
    histograms (`time_to_first_token_seconds`, `time_per_output_token_seconds`).
  - Aggregate "system tok/s" = (sum_tokens / wall_time) across concurrent
    requests is also reported — useful for capacity sizing.

Output: human report to stdout + optional markdown to reports/.

Usage:
    # Port-forward first:
    kubectl -n llm-chat port-forward svc/vllm-server 8000:8000 &

    # Single-request sanity check
    python scripts/bench_vllm.py --concurrency 1 --requests 5

    # Concurrency sweep
    python scripts/bench_vllm.py \\
        --concurrency 1,4,8 \\
        --requests 20 \\
        --prompt-tokens 3000 \\
        --new-tokens 400 \\
        --out reports/p2-vllm-bench.md
"""
from __future__ import annotations

import argparse
import asyncio
import json
import os
import statistics
import sys
import time
from dataclasses import asdict, dataclass
from typing import Any

try:
    import httpx
except ImportError:
    sys.stderr.write(
        "missing dependency: pip install httpx\n"
        "  (used to drive the OpenAI-compatible /v1/chat/completions endpoint)\n"
    )
    sys.exit(1)


@dataclass
class Result:
    ok: bool
    e2e_ms: float
    ttft_ms: float                # time-to-first-token (≈ prefill latency)
    decode_ms: float              # e2e - ttft
    prompt_tokens: int
    completion_tokens: int
    error: str | None = None

    @property
    def total_tokens(self) -> int:
        return self.prompt_tokens + self.completion_tokens

    @property
    def prefill_tps(self) -> float:
        if self.ttft_ms <= 0 or self.prompt_tokens <= 0:
            return 0.0
        return self.prompt_tokens / (self.ttft_ms / 1000.0)

    @property
    def decode_tps(self) -> float:
        if self.decode_ms <= 0 or self.completion_tokens <= 0:
            return 0.0
        return self.completion_tokens / (self.decode_ms / 1000.0)


# A real RAG prompt is mostly retrieved context. We pad with a deterministic
# Vietnamese filler so the tokenizer sees realistic char distribution.
FILLER_VI = (
    "Aposa cung cấp các API quản lý tài khoản, thiết bị và token. "
    "Hệ thống được triển khai trên cụm Kubernetes ở vùng us-west-2 "
    "với GPU NVIDIA T4 cho lab nhỏ hoặc L4/A10G cho profile stable. "
)


def build_prompt(prompt_tokens: int) -> str:
    """Pad context to roughly N tokens (rough char-based estimate: ~3.2 chars/tok VN)."""
    target_chars = max(1, int(prompt_tokens * 3.2))
    reps = target_chars // len(FILLER_VI) + 1
    return (FILLER_VI * reps)[:target_chars]


def build_messages(prompt_tokens: int) -> list[dict[str, str]]:
    context = build_prompt(prompt_tokens)
    return [
        {
            "role": "system",
            "content": (
                "Bạn là trợ lý trả lời dựa trên CONTEXT. Trả lời ngắn gọn, "
                "không bịa, dẫn nguồn [N] khi có thể."
            ),
        },
        {
            "role": "user",
            "content": f"CONTEXT:\n{context}\n\nCÂU HỎI: Aposa có những API nào để quản lý token?\nTRẢ LỜI:",
        },
    ]


def _parse_sse_chunk(line: str) -> dict[str, Any] | None:
    """OpenAI streaming uses `data: {json}` SSE frames terminated by `data: [DONE]`."""
    if not line.startswith("data:"):
        return None
    payload = line[len("data:"):].strip()
    if not payload or payload == "[DONE]":
        return None
    try:
        return json.loads(payload)
    except json.JSONDecodeError:
        return None


async def one_request(
    client: httpx.AsyncClient,
    url: str,
    model: str,
    messages: list[dict[str, str]],
    new_tokens: int,
    timeout_s: float,
) -> Result:
    """
    Streaming call. Records:
      - TTFT = client wall time from request send to first non-empty content chunk
      - e2e  = client wall time end-to-end
      - usage tokens from the final SSE frame (vllm includes `usage` in the
        last chunk; OpenAI spec extension widely supported).
    """
    payload = {
        "model": model,
        "messages": messages,
        "temperature": 0.2,
        "top_p": 0.85,
        "max_tokens": new_tokens,
        "stream": True,
        "stream_options": {"include_usage": True},   # vllm honors this — final chunk has `usage`
    }
    t0 = time.perf_counter()
    ttft_ms = 0.0
    prompt_tokens = 0
    completion_tokens = 0
    saw_first_content = False

    try:
        async with client.stream("POST", url, json=payload, timeout=timeout_s) as r:
            if r.status_code != 200:
                body = (await r.aread()).decode("utf-8", errors="replace")[:200]
                e2e_ms = (time.perf_counter() - t0) * 1000.0
                return Result(False, e2e_ms, 0.0, 0.0, 0, 0, error=f"http {r.status_code}: {body}")

            async for raw_line in r.aiter_lines():
                if not raw_line:
                    continue
                chunk = _parse_sse_chunk(raw_line)
                if chunk is None:
                    continue

                # First content delta marks the prefill→decode boundary.
                if not saw_first_content:
                    choices = chunk.get("choices") or []
                    for c in choices:
                        delta = c.get("delta") or {}
                        if delta.get("content"):
                            ttft_ms = (time.perf_counter() - t0) * 1000.0
                            saw_first_content = True
                            break

                # vllm emits usage in the terminal chunk (after [DONE] frames in
                # some versions, but typically as the last data frame).
                usage = chunk.get("usage")
                if usage:
                    prompt_tokens = int(usage.get("prompt_tokens", 0))
                    completion_tokens = int(usage.get("completion_tokens", 0))

        e2e_ms = (time.perf_counter() - t0) * 1000.0
        if not saw_first_content:
            # Server returned an empty completion or all SSE frames were
            # control-only — treat as soft failure for measurement, not crash.
            return Result(False, e2e_ms, 0.0, 0.0, prompt_tokens, completion_tokens, error="no content chunks")
        decode_ms = max(0.0, e2e_ms - ttft_ms)
        return Result(
            ok=True,
            e2e_ms=e2e_ms,
            ttft_ms=ttft_ms,
            decode_ms=decode_ms,
            prompt_tokens=prompt_tokens,
            completion_tokens=completion_tokens,
        )
    except Exception as exc:  # noqa: BLE001 — bench should report, not crash
        e2e_ms = (time.perf_counter() - t0) * 1000.0
        return Result(False, e2e_ms, 0.0, 0.0, 0, 0, error=repr(exc))


async def run_burst(
    base_url: str,
    model: str,
    concurrency: int,
    requests: int,
    prompt_tokens: int,
    new_tokens: int,
    timeout_s: float,
) -> list[Result]:
    messages = build_messages(prompt_tokens)
    url = base_url.rstrip("/") + "/v1/chat/completions"

    limits = httpx.Limits(max_connections=concurrency * 2, max_keepalive_connections=concurrency)
    async with httpx.AsyncClient(limits=limits) as client:
        sem = asyncio.Semaphore(concurrency)

        async def worker(_idx: int) -> Result:
            async with sem:
                return await one_request(client, url, model, messages, new_tokens, timeout_s)

        tasks = [asyncio.create_task(worker(i)) for i in range(requests)]
        return await asyncio.gather(*tasks)


def _pct(values: list[float], q: float) -> float:
    if not values:
        return 0.0
    s = sorted(values)
    idx = min(len(s) - 1, int(len(s) * q))
    return s[idx]


def summarize(results: list[Result], wall_s: float) -> dict[str, Any]:
    ok = [r for r in results if r.ok]
    fail = [r for r in results if not r.ok]
    if not ok:
        return {
            "ok": 0,
            "fail": len(fail),
            "errors": [r.error for r in fail[:3]],
        }

    e2e = [r.e2e_ms for r in ok]
    ttft = [r.ttft_ms for r in ok]
    prefill_tps = [r.prefill_tps for r in ok if r.prefill_tps > 0]
    decode_tps = [r.decode_tps for r in ok if r.decode_tps > 0]
    prompt = sum(r.prompt_tokens for r in ok)
    completion = sum(r.completion_tokens for r in ok)
    total_tokens = prompt + completion

    return {
        "ok": len(ok),
        "fail": len(fail),
        "errors": [r.error for r in fail[:3]] if fail else [],

        # End-to-end latency (client wall time)
        "e2e_ms_p50": _pct(e2e, 0.50),
        "e2e_ms_p95": _pct(e2e, 0.95),
        "e2e_ms_mean": statistics.fmean(e2e),

        # Prefill phase — measured via TTFT (first content chunk)
        "ttft_ms_p50": _pct(ttft, 0.50),
        "ttft_ms_p95": _pct(ttft, 0.95),
        "prefill_tps_p50": _pct(prefill_tps, 0.50),
        "prefill_tps_p95": _pct(prefill_tps, 0.95),

        # Decode phase — completion_tokens / (e2e - ttft) per request
        "decode_tps_p50": _pct(decode_tps, 0.50),
        "decode_tps_p95": _pct(decode_tps, 0.95),

        "prompt_tokens_total": prompt,
        "completion_tokens_total": completion,

        # Aggregate throughput across all in-flight requests
        "system_tokens_per_s": total_tokens / wall_s if wall_s > 0 else 0.0,
        "completion_tokens_per_s": completion / wall_s if wall_s > 0 else 0.0,
    }


def render_markdown(rows: list[dict[str, Any]], args: argparse.Namespace) -> str:
    out: list[str] = []
    out.append("# vLLM bench (P2 smoke)\n")
    out.append(f"- url: `{args.base_url}`")
    out.append(f"- model: `{args.model}`")
    out.append(f"- prompt_tokens (target): {args.prompt_tokens}")
    out.append(f"- new_tokens: {args.new_tokens}")
    out.append(f"- requests per concurrency: {args.requests}")
    out.append("- protocol: SSE streaming (`stream_options.include_usage=true`)")
    out.append("")
    out.append(
        "**Per-request latency** (client-side; TTFT = first content chunk)\n"
    )
    out.append("| c | ok/fail | e2e p50/p95 ms | TTFT p50/p95 ms | prefill tok/s p50 | decode tok/s p50 |")
    out.append("|---:|---:|---:|---:|---:|---:|")
    for row in rows:
        s = row["summary"]
        if "e2e_ms_p50" not in s:
            out.append(f"| {row['concurrency']} | 0/{s['fail']} | — | — | — | — |")
            continue
        out.append(
            f"| {row['concurrency']} | {s['ok']}/{s['fail']} | "
            f"{s['e2e_ms_p50']:.0f} / {s['e2e_ms_p95']:.0f} | "
            f"{s['ttft_ms_p50']:.0f} / {s['ttft_ms_p95']:.0f} | "
            f"{s['prefill_tps_p50']:.0f} | {s['decode_tps_p50']:.0f} |"
        )
    out.append("")
    out.append("**Aggregate throughput** (sum of tokens across in-flight ÷ wall time)\n")
    out.append("| c | system tok/s | gen tok/s | wall s |")
    out.append("|---:|---:|---:|---:|")
    for row in rows:
        s = row["summary"]
        if "system_tokens_per_s" not in s:
            out.append(f"| {row['concurrency']} | — | — | {row['wall_s']:.1f} |")
            continue
        out.append(
            f"| {row['concurrency']} | "
            f"{s['system_tokens_per_s']:.1f} | "
            f"{s['completion_tokens_per_s']:.1f} | "
            f"{row['wall_s']:.1f} |"
        )
    out.append("")
    if any(row["summary"].get("errors") for row in rows):
        out.append("### Errors (first 3 per row)\n")
        for row in rows:
            errs = row["summary"].get("errors") or []
            if errs:
                out.append(f"- c={row['concurrency']}: {errs}")
        out.append("")
    out.append("> Note: numbers are client-side and include network/SSE overhead. For point-in-time engine truth, scrape `vllm:time_to_first_token_seconds` and `vllm:time_per_output_token_seconds` from `/metrics`.")
    return "\n".join(out)


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--base-url", default=os.environ.get("VLLM_BASE_URL", "http://localhost:8000"))
    p.add_argument("--model", default=os.environ.get("VLLM_SERVED_MODEL", "qwen-rag"))
    p.add_argument(
        "--concurrency",
        default="1",
        help="comma-separated list, e.g. '1,4,8'",
    )
    p.add_argument("--requests", type=int, default=10)
    p.add_argument("--prompt-tokens", type=int, default=3000, dest="prompt_tokens")
    p.add_argument("--new-tokens", type=int, default=400, dest="new_tokens")
    p.add_argument("--timeout", type=float, default=120.0)
    p.add_argument("--out", default="", help="optional markdown report path")
    return p.parse_args()


async def main_async(args: argparse.Namespace) -> int:
    concurrencies = [int(c) for c in args.concurrency.split(",") if c.strip()]
    rows: list[dict[str, Any]] = []
    for c in concurrencies:
        print(f"==> concurrency={c} requests={args.requests} prompt~={args.prompt_tokens} tok")
        t0 = time.perf_counter()
        results = await run_burst(
            base_url=args.base_url,
            model=args.model,
            concurrency=c,
            requests=args.requests,
            prompt_tokens=args.prompt_tokens,
            new_tokens=args.new_tokens,
            timeout_s=args.timeout,
        )
        wall = time.perf_counter() - t0
        summary = summarize(results, wall)
        rows.append({"concurrency": c, "wall_s": wall, "summary": summary})
        print(json.dumps({"concurrency": c, "wall_s": round(wall, 2), **summary}, indent=2))

    if args.out:
        path = args.out
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        with open(path, "w") as f:
            f.write(render_markdown(rows, args))
        print(f"==> wrote {path}")
    return 0


def main() -> int:
    args = parse_args()
    return asyncio.run(main_async(args))


if __name__ == "__main__":
    raise SystemExit(main())
