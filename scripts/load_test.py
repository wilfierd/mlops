import argparse
import asyncio
import json
import os
import statistics
import time
from collections import Counter
from pathlib import Path

import httpx


def percentile(values: list[float], p: float) -> float:
    if not values:
        return float("nan")
    if len(values) == 1:
        return values[0]
    sorted_values = sorted(values)
    k = (len(sorted_values) - 1) * p
    f = int(k)
    c = min(f + 1, len(sorted_values) - 1)
    if f == c:
        return sorted_values[f]
    return sorted_values[f] + (sorted_values[c] - sorted_values[f]) * (k - f)


async def send_one(client: httpx.AsyncClient, url: str, index: int, max_new_tokens: int, timeout: float) -> dict:
    started = time.perf_counter()
    payload = {
        "messages": [
            {
                "role": "user",
                "content": f"Tra loi ngan gon bang tieng Viet: request {index} la gi?",
            }
        ],
        "max_new_tokens": max_new_tokens,
        "temperature": 0.2,
    }
    try:
        response = await client.post(url, json=payload, timeout=timeout)
        elapsed = time.perf_counter() - started
        if response.status_code >= 400:
            return {"index": index, "ok": False, "elapsed": elapsed, "status": response.status_code, "replica": None, "answer_len": 0}
        data = response.json()
        answer = data.get("answer", "") or ""
        return {
            "index": index,
            "ok": True,
            "elapsed": elapsed,
            "status": response.status_code,
            "replica": data.get("replica"),
            "answer_len": len(answer),
            "max_new_tokens": max_new_tokens,
        }
    except Exception as exc:
        return {"index": index, "ok": False, "elapsed": time.perf_counter() - started, "error": repr(exc), "replica": None, "answer_len": 0}


async def warmup(client: httpx.AsyncClient, url: str, count: int, max_new_tokens: int, timeout: float) -> None:
    if count <= 0:
        return
    print(f"[warmup] {count} request(s)")
    tasks = [send_one(client, url, -i - 1, max_new_tokens, timeout) for i in range(count)]
    await asyncio.gather(*tasks, return_exceptions=True)


async def run_pool(client: httpx.AsyncClient, url: str, concurrency: int, requests: int, max_new_tokens: int, timeout: float) -> list[dict]:
    pending: set[asyncio.Task] = set()
    next_id = 0
    results: list[dict] = []

    while next_id < requests or pending:
        while next_id < requests and len(pending) < concurrency:
            next_id += 1
            pending.add(asyncio.create_task(send_one(client, url, next_id, max_new_tokens, timeout)))

        done, pending = await asyncio.wait(pending, return_when=asyncio.FIRST_COMPLETED)
        for task in done:
            result = task.result()
            results.append(result)
            status_tag = "ok" if result["ok"] else "FAIL"
            print(f"{result['index']:04d} {result['elapsed']:6.2f}s {status_tag} replica={result.get('replica')} bytes={result.get('answer_len')}")

    return results


def summarize(results: list[dict], wall_seconds: float) -> dict:
    ok = [r for r in results if r["ok"]]
    failed = [r for r in results if not r["ok"]]
    latencies = [r["elapsed"] for r in ok]
    total_tokens = sum(r.get("max_new_tokens", 0) for r in ok)
    replica_counter = Counter(r.get("replica") for r in ok if r.get("replica"))

    summary = {
        "total": len(results),
        "ok": len(ok),
        "failed": len(failed),
        "error_rate": (len(failed) / len(results)) if results else 0.0,
        "wall_seconds": round(wall_seconds, 2),
        "throughput_rps": round(len(ok) / wall_seconds, 2) if wall_seconds > 0 else 0.0,
        "tokens_per_s_upper_bound": round(total_tokens / wall_seconds, 2) if wall_seconds > 0 else 0.0,
        "latency": {
            "min": round(min(latencies), 3) if latencies else None,
            "mean": round(statistics.mean(latencies), 3) if latencies else None,
            "p50": round(percentile(latencies, 0.50), 3) if latencies else None,
            "p90": round(percentile(latencies, 0.90), 3) if latencies else None,
            "p95": round(percentile(latencies, 0.95), 3) if latencies else None,
            "p99": round(percentile(latencies, 0.99), 3) if latencies else None,
            "max": round(max(latencies), 3) if latencies else None,
        },
        "replica_distribution": dict(replica_counter),
        "unique_replicas": len(replica_counter),
    }
    return summary


def print_summary(summary: dict) -> None:
    print()
    print("=" * 60)
    print("SUMMARY")
    print("=" * 60)
    print(f"requests       : {summary['total']} (ok={summary['ok']} failed={summary['failed']} error_rate={summary['error_rate']:.2%})")
    print(f"wall time      : {summary['wall_seconds']}s")
    print(f"throughput     : {summary['throughput_rps']} req/s")
    print(f"tokens/s (cap) : {summary['tokens_per_s_upper_bound']}  (upper bound assuming max_new_tokens)")
    lat = summary["latency"]
    if lat["p50"] is not None:
        print(f"latency (s)    : min={lat['min']} mean={lat['mean']} p50={lat['p50']} p90={lat['p90']} p95={lat['p95']} p99={lat['p99']} max={lat['max']}")
    print(f"unique replicas: {summary['unique_replicas']}")
    for replica, count in summary["replica_distribution"].items():
        print(f"  - {replica}: {count}")


async def run(args: argparse.Namespace) -> dict:
    limits = httpx.Limits(max_connections=args.concurrency, max_keepalive_connections=args.concurrency)
    async with httpx.AsyncClient(limits=limits) as client:
        await warmup(client, args.url, args.warmup, args.max_new_tokens, args.timeout)
        started = time.perf_counter()
        results = await run_pool(client, args.url, args.concurrency, args.requests, args.max_new_tokens, args.timeout)
        wall = time.perf_counter() - started

    summary = summarize(results, wall)
    print_summary(summary)

    if args.output:
        out_path = Path(args.output)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        with out_path.open("w") as f:
            json.dump({"args": vars(args), "summary": summary, "results": results}, f, indent=2)
        print(f"\nwrote {out_path}")

    return summary


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", default="http://127.0.0.1:8000/chat")
    parser.add_argument("--concurrency", type=int, default=8)
    parser.add_argument("--requests", type=int, default=24)
    parser.add_argument("--warmup", type=int, default=2, help="warmup requests excluded from stats")
    parser.add_argument("--max-new-tokens", type=int, default=64)
    parser.add_argument("--timeout", type=float, default=180.0)
    parser.add_argument("--output", default=os.getenv("LOAD_TEST_OUTPUT", ""), help="path to JSON report")
    args = parser.parse_args()

    asyncio.run(run(args))


if __name__ == "__main__":
    main()
