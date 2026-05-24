#!/usr/bin/env python3
"""P9 eval runner: upload seed docs → poll until ready → run /qa for each question
→ check keyword pass/fail → report latency percentiles and pass rate.

Usage:
    python scripts/eval_qa.py --base-url http://localhost:8000 \
        --seed-dir data/seed --eval-file data/eval/eval_questions.jsonl

Exit code: 0 if pass_rate >= --min-pass-rate (default 0.7), else 1.
"""
from __future__ import annotations

import argparse
import json
import statistics
import sys
import time
from pathlib import Path

import httpx


# ── helpers ──────────────────────────────────────────────────────────────────

def upload_doc(client: httpx.Client, base_url: str, path: Path) -> str:
    with path.open("rb") as fh:
        r = client.post(
            f"{base_url}/documents",
            files={"file": (path.name, fh, _mime(path))},
            timeout=30,
        )
    r.raise_for_status()
    data = r.json()
    doc_id: str = data["doc_id"]
    print(f"  uploaded {path.name} → doc_id={doc_id} status={data['status']}")
    return doc_id


def _mime(path: Path) -> str:
    ext = path.suffix.lower()
    return {"md": "text/markdown", "txt": "text/plain", "pdf": "application/pdf"}.get(ext.lstrip("."), "text/plain")


def poll_until_ready(client: httpx.Client, base_url: str, doc_ids: list[str], timeout_s: int = 300) -> None:
    deadline = time.monotonic() + timeout_s
    pending = set(doc_ids)
    while pending and time.monotonic() < deadline:
        for did in list(pending):
            r = client.get(f"{base_url}/documents/{did}", timeout=10)
            if r.status_code == 200:
                status = r.json().get("status")
                if status == "ready":
                    print(f"  {did} ready")
                    pending.discard(did)
                elif status == "failed":
                    print(f"  WARNING: {did} failed — {r.json().get('error_code')}", file=sys.stderr)
                    pending.discard(did)
        if pending:
            time.sleep(5)
    if pending:
        raise TimeoutError(f"Docs not ready after {timeout_s}s: {pending}")


def ask_qa(
    client: httpx.Client,
    base_url: str,
    question: str,
    doc_ids: list[str],
    score_threshold: float = 0.5,
) -> tuple[dict, float]:
    t0 = time.monotonic()
    r = client.post(
        f"{base_url}/qa",
        json={"question": question, "doc_ids": doc_ids, "top_k": 5, "score_threshold": score_threshold},
        timeout=90,
    )
    wall_ms = (time.monotonic() - t0) * 1000
    r.raise_for_status()
    return r.json(), wall_ms


def check_keywords(answer: str, keywords: list[str]) -> tuple[bool, list[str]]:
    answer_lower = answer.lower()
    missing = [kw for kw in keywords if kw.lower() not in answer_lower]
    return len(missing) == 0, missing


# ── main ─────────────────────────────────────────────────────────────────────

def main() -> int:
    parser = argparse.ArgumentParser(description="RAG eval runner")
    parser.add_argument("--base-url", default="http://localhost:8000")
    parser.add_argument("--seed-dir", default="data/seed")
    parser.add_argument("--eval-file", default="data/eval/eval_questions.jsonl")
    parser.add_argument("--min-pass-rate", type=float, default=0.7, help="Fail exit if pass rate below this")
    parser.add_argument("--skip-upload", action="store_true", help="Skip doc upload (docs already indexed)")
    parser.add_argument("--output-json", default="", help="Optional path to write full results JSON")
    args = parser.parse_args()

    seed_dir = Path(args.seed_dir)
    eval_file = Path(args.eval_file)

    client = httpx.Client()

    # ── Step 1: Upload seed docs ─────────────────────────────────────────────
    doc_ids: list[str] = []
    if not args.skip_upload:
        print("\n=== Uploading seed documents ===")
        seed_files = sorted(seed_dir.glob("*.md")) + sorted(seed_dir.glob("*.txt"))
        if not seed_files:
            print(f"ERROR: no .md/.txt files in {seed_dir}", file=sys.stderr)
            return 1
        for p in seed_files:
            did = upload_doc(client, args.base_url, p)
            doc_ids.append(did)

        # ── Step 2: Poll until all docs are ready ────────────────────────────
        print("\n=== Waiting for ingest to complete ===")
        poll_until_ready(client, args.base_url, doc_ids)
    else:
        print("=== Skipping upload (--skip-upload) ===")
        r = client.get(f"{args.base_url}/documents", timeout=15)
        r.raise_for_status()
        doc_ids = [d["doc_id"] for d in r.json() if d.get("status") == "ready"]
        print(f"  found {len(doc_ids)} ready docs")

    # ── Step 3: Run eval questions ────────────────────────────────────────────
    print(f"\n=== Running eval from {eval_file} ===")
    questions = [json.loads(line) for line in eval_file.read_text().splitlines() if line.strip()]

    results = []
    wall_times: list[float] = []
    total_latency_ms: list[float] = []

    for q in questions:
        qid = q["id"]
        question = q["question"]
        keywords = q.get("expected_keywords", [])

        score_threshold = q.get("score_threshold", 0.5)
        try:
            resp, wall_ms = ask_qa(client, args.base_url, question, doc_ids, score_threshold)
        except Exception as exc:
            print(f"  [{qid}] ERROR: {exc}")
            results.append({"id": qid, "pass": False, "error": str(exc)})
            continue

        answer = resp.get("answer", "")
        fallback = resp.get("fallback_reason")
        lat_ms = resp.get("latency_ms", {})
        total_ms = lat_ms.get("total", wall_ms)

        passed, missing = check_keywords(answer, keywords)
        wall_times.append(wall_ms)
        total_latency_ms.append(total_ms)

        status = "PASS" if passed else "FAIL"
        fallback_note = f" [fallback={fallback}]" if fallback else ""
        missing_note = f" missing={missing}" if missing else ""
        print(f"  [{qid}] {status}{fallback_note} | total={total_ms:.0f}ms{missing_note}")

        results.append({
            "id": qid,
            "question": question,
            "pass": passed,
            "fallback_reason": fallback,
            "missing_keywords": missing,
            "answer_snippet": answer[:200],
            "latency_ms": lat_ms,
            "wall_ms": round(wall_ms),
        })

    # ── Step 4: Summary ───────────────────────────────────────────────────────
    n = len(results)
    passed_n = sum(1 for r in results if r.get("pass"))
    pass_rate = passed_n / n if n else 0.0

    print(f"\n=== Results ===")
    print(f"Total questions : {n}")
    print(f"Passed          : {passed_n}/{n} ({pass_rate*100:.1f}%)")

    if total_latency_ms:
        sorted_lat = sorted(total_latency_ms)
        p50 = statistics.median(sorted_lat)
        p95 = sorted_lat[int(len(sorted_lat) * 0.95)]
        print(f"Latency p50     : {p50:.0f}ms")
        print(f"Latency p95     : {p95:.0f}ms")

    if args.output_json:
        out = Path(args.output_json)
        out.write_text(json.dumps({"pass_rate": pass_rate, "results": results}, ensure_ascii=False, indent=2))
        print(f"Full results written to {out}")

    return 0 if pass_rate >= args.min_pass_rate else 1


if __name__ == "__main__":
    sys.exit(main())
