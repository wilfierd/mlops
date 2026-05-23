# P3 — Qdrant collocate + PV bind verification

End-to-end runbook for deploying Qdrant on the head node and verifying the retained-EBS data-persistence guarantee.

## Prerequisites

- `persistent/` stack applied — creates EBS volume `qdrant-data` (vol-XXXX).
- `cluster-up` ran successfully — ephemeral stack creates PV `qdrant-data-pv` + PVC `qdrant-data-pvc` that bind to that EBS volume.

```bash
make -C infra cluster-status
# Expect: head Ready, node-type=head

kubectl get pv qdrant-data-pv
# Expect STATUS=Available (or Bound after first pod attach)

kubectl -n llm-chat get pvc qdrant-data-pvc
# Expect STATUS=Pending (WaitForFirstConsumer) — Qdrant pod will bind it
```

## 1. Deploy + init collection

```bash
make -C infra qdrant-up
```

What happens (~30 s cold, <10 s if image cached):

1. `kubectl apply -f k8s/qdrant.yaml` — creates headless Service + StatefulSet
2. K8s schedules `qdrant-0` onto head node (nodeSelector + taint toleration)
3. EBS CSI binds `qdrant-data-pvc` → `qdrant-data-pv` → `vol-XXXX` in head AZ
4. Qdrant starts → readinessProbe `/readyz` on :6333 goes green (≤ 30 s)
5. `make qdrant-init` runs — opens temp port-forward, creates `documents` collection (idempotent)

To re-run collection init independently (e.g. after manual collection drop):

```bash
make -C infra qdrant-init
# Opens a temp port-forward internally, runs scripts/qdrant_init.py, closes port-forward.
```

## 2. Smoke-check the server

```bash
# Terminal A — leave it running
make -C infra qdrant-pf

# Terminal B — REST API
curl -s http://localhost:6333/readyz
# Expect: {"ok":true} or HTTP 200 OK

curl -s http://localhost:6333/collections | jq .
# Expect: result.collections contains "documents"
```

## 3. Smoke upsert/search

```bash
# Upsert a test point.
# Use a non-zero vector — Cosine distance requires non-zero norm.
SMOKE_VEC=$(python3 -c 'import json; v=[0.0]*384; v[0]=1.0; print(json.dumps(v))')

curl -s -X PUT http://localhost:6333/collections/documents/points \
  -H 'content-type: application/json' \
  -d '{
    "points": [{
      "id": "p3-smoke:0",
      "vector": '"$SMOKE_VEC"',
      "payload": {"doc_id": "p3-smoke", "chunk_idx": 0, "text": "P3 smoke test chunk"}
    }]
  }' | jq .
# Expect: {"result":{"operation_id":0,"status":"completed"},"status":"ok",...}

# Verify search returns the point
curl -s -X POST http://localhost:6333/collections/documents/points/search \
  -H 'content-type: application/json' \
  -d '{"vector": '"$SMOKE_VEC"', "limit": 3, "with_payload": true}' | jq .
# Expect: result[0].payload.doc_id == "p3-smoke", score ≈ 1.0

# Exact point count (avoid vectors_count which counts named-vector slots, not points)
curl -s -X POST http://localhost:6333/collections/documents/points/count \
  -H 'content-type: application/json' \
  -d '{"exact": true}' | jq .result.count
# Expect: 1
```

## 4. Persistence check — destroy/recreate cluster

Verifies the EBS Retain policy end-to-end.

```bash
# Record count before destroy
BEFORE=$(curl -s -X POST http://localhost:6333/collections/documents/points/count \
  -H 'content-type: application/json' -d '{"exact":true}' | jq .result.count)
echo "points before: $BEFORE"
# Kill port-forward (Ctrl-C in Terminal A)

# Destroy ephemeral stack (EBS vol-XXXX is NOT destroyed — lives in persistent stack)
make -C infra cluster-down
# Expect: "EBS qdrant + llm-cache retained for next cluster-up."

# Recreate cluster + redeploy Qdrant (also re-runs qdrant-init, which is idempotent)
make -C infra cluster-up
make -C infra qdrant-up

# Port-forward again
make -C infra qdrant-pf &
sleep 3

# Verify data survived
AFTER=$(curl -s -X POST http://localhost:6333/collections/documents/points/count \
  -H 'content-type: application/json' -d '{"exact":true}' | jq .result.count)
echo "points after recreate: $AFTER"
# Expect: $AFTER == $BEFORE (data on EBS survived destroy/recreate)
```

## 5. Tear down

```bash
make -C infra qdrant-down
# Deletes StatefulSet + Service. qdrant-data-pvc and EBS data are NOT removed.
```

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `qdrant-0` stuck `Pending` | EBS PV not in same AZ as head node | `kubectl describe pod qdrant-0` → check "volume node affinity conflict"; verify `worker_az` in persistent tfvars matches head MNG AZ |
| `qdrant-0` stuck `Pending` "1 node(s) had taint" | Toleration missing or wrong value | Check toleration `key=ray-role, value=head, effect=NoSchedule` in `k8s/qdrant.yaml`; `kubectl describe node <head>` to see exact taint |
| `qdrant-data-pvc` stays `Pending` after pod schedules | EBS CSI IRSA not wired | `kubectl -n kube-system logs deploy/ebs-csi-controller -c csi-provisioner` |
| `/readyz` returns 503 after pod `Running` | Qdrant still loading WAL | Wait; check `kubectl -n llm-chat logs qdrant-0` for "Qdrant gRPC listening" |
| `points/count` returns 0 after recreate | PVC bound to wrong PV (new dynamic PV instead of retained one) | Check `kubectl get pvc qdrant-data-pvc -n llm-chat -o jsonpath='{.spec.volumeName}'` — must be `qdrant-data-pv`, not a dynamic claim |
| PV stays `Released` after destroy | Old `claimRef` lingers | `kubectl patch pv qdrant-data-pv -p '{"spec":{"claimRef":null}}'` then re-apply |
