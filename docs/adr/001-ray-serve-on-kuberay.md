# 001 — Ray Serve via KubeRay (vs BentoML, vLLM, raw Deployment)

Status: accepted
Date: 2026-05-15

## Context

Need to host a small LLM on CPU with HTTP API, autoscale by concurrent
request. Candidates: BentoML, vLLM serve, FastAPI + Deployment + HPA,
Ray Serve on KubeRay.

## Decision

Ray Serve via KubeRay `RayService` CR.

## Consequences

- Built-in autoscale by `target_ongoing_requests` (req-aware, not CPU-aware
  like HPA) — exactly right for LLM where one request = one CPU-bound burst.
- Replica = Ray actor, free dynamic batching when we want it (`@serve.batch`)
  later.
- Cluster runs Ray head + workers, more moving parts than a single Deployment.
- Adds the KubeRay operator to the cluster (small ~100MB pod).
- vLLM ruled out: GPU-only support is mature, CPU backend is experimental.
- BentoML ruled out: serving framework but autoscale story still leans on HPA.
