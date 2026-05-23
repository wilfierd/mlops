#!/usr/bin/env python3
"""
Smoke benchmark for the P4 /embed endpoint.
"""
from __future__ import annotations

import argparse
import statistics
import time
from typing import Any

import httpx


TEXT = (
    "Aposa cung cấp API quản lý token, thiết bị và tài khoản. "
    "Đây là câu kiểm thử tiếng Việt cho embedder multilingual-e5-small."
)


def percentile(values: list[float], q: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    idx = min(len(ordered) - 1, int(len(ordered) * q))
    return ordered[idx]


def run_batch(client: httpx.Client, url: str, batch_size: int, requests: int) -> dict[str, Any]:
    latencies: list[float] = []
    failures = 0
    dim = 0
    payload = {
        "texts": [f"{TEXT} #{i}" for i in range(batch_size)],
        "input_type": "query",
    }
    for _ in range(requests):
        started = time.perf_counter()
        response = client.post(url, json=payload)
        elapsed_ms = (time.perf_counter() - started) * 1000.0
        if response.status_code != 200:
            failures += 1
            continue
        body = response.json()
        dim = int(body.get("dim", 0))
        if len(body.get("vectors", [])) != batch_size:
            failures += 1
            continue
        latencies.append(elapsed_ms)
    return {
        "batch": batch_size,
        "ok": len(latencies),
        "fail": failures,
        "dim": dim,
        "p50_ms": percentile(latencies, 0.50),
        "p95_ms": percentile(latencies, 0.95),
        "mean_ms": statistics.fmean(latencies) if latencies else 0.0,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", default="http://localhost:8000")
    parser.add_argument("--batches", default="1,32")
    parser.add_argument("--requests", type=int, default=20)
    parser.add_argument("--timeout", type=float, default=30.0)
    args = parser.parse_args()

    url = args.base_url.rstrip("/") + "/embed"
    batch_sizes = [int(item) for item in args.batches.split(",") if item.strip()]
    with httpx.Client(timeout=args.timeout) as client:
        for batch_size in batch_sizes:
            row = run_batch(client, url, batch_size, args.requests)
            print(
                "batch={batch} ok={ok} fail={fail} dim={dim} "
                "p50={p50_ms:.1f}ms p95={p95_ms:.1f}ms mean={mean_ms:.1f}ms".format(**row)
            )
            if row["fail"]:
                return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
