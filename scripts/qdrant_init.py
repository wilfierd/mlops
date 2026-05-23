#!/usr/bin/env python3
"""
Idempotent Qdrant collection init for P3.

Creates (or verifies) the 'documents' collection used by Embedder and QA:
  - 384-dim cosine, vectors in RAM (on_disk=false)
  - HNSW m=16, ef_construct=128, index on disk
  - Optimizers: memmap_threshold=20000, indexing_threshold=10000

Safe to run multiple times — if the collection already exists the script
just prints its current config and exits 0.

Usage:
    # Port-forward must be running first:
    #   kubectl -n llm-chat port-forward pod/qdrant-0 6333:6333 &
    python scripts/qdrant_init.py

    # Or point at a different URL:
    python scripts/qdrant_init.py --base-url http://qdrant-0.qdrant.llm-chat.svc.cluster.local:6333
"""
from __future__ import annotations

import argparse
import json
import sys

try:
    import httpx
except ImportError:
    sys.stderr.write("missing dependency: pip install httpx\n")
    sys.exit(1)

COLLECTION_SCHEMA = {
    "vectors": {
        "size": 384,
        "distance": "Cosine",
        "on_disk": False,
    },
    "hnsw_config": {
        "m": 16,
        "ef_construct": 128,
        "on_disk": True,
    },
    "optimizers_config": {
        "memmap_threshold": 20000,
        "indexing_threshold": 10000,
        "default_segment_number": 2,
    },
}


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--base-url", default="http://localhost:6333")
    p.add_argument("--collection", default="documents")
    args = p.parse_args()

    base = args.base_url.rstrip("/")
    coll = args.collection

    with httpx.Client(timeout=10.0) as client:
        # 1. Check if collection already exists.
        resp = client.get(f"{base}/collections/{coll}")
        if resp.status_code == 200:
            info = resp.json().get("result", {})
            count = info.get("points_count", "?")
            print(f"collection '{coll}' already exists — points_count={count}. Nothing to do.")
            return 0
        if resp.status_code != 404:
            print(f"ERROR: GET /collections/{coll} returned {resp.status_code}: {resp.text[:200]}", file=sys.stderr)
            return 1

        # 2. Create collection.
        print(f"creating collection '{coll}'...")
        resp = client.put(
            f"{base}/collections/{coll}",
            headers={"content-type": "application/json"},
            content=json.dumps(COLLECTION_SCHEMA),
        )
        if resp.status_code not in (200, 201):
            print(f"ERROR: PUT /collections/{coll} returned {resp.status_code}: {resp.text[:200]}", file=sys.stderr)
            return 1

        body = resp.json()
        if not body.get("result"):
            print(f"ERROR: unexpected response: {body}", file=sys.stderr)
            return 1

        print(f"collection '{coll}' created.")
        print(f"  vectors: 384-dim cosine, on_disk=false")
        print(f"  hnsw: m=16 ef_construct=128 on_disk=true")
        print(f"  optimizers: memmap_threshold=20000 indexing_threshold=10000")
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
