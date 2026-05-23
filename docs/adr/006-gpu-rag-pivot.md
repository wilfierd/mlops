# 006 — GPU RAG pivot

Status: accepted
Date: 2026-05-24

## Context

The CPU-only Qwen 0.5B/0.6B path was cheap but did not meet the quality and
latency target for document Q&A with multi-thousand-token context. The RAG
path also needs persistent vector storage and a model cache that survives
cluster destroy/apply cycles.

## Decision

Use a split architecture: Ray Serve on the x86 head node for API + ONNX
embedder, Qdrant on persistent EBS for vectors, and vLLM on a GPU node for the
LLM.

## Consequences

- The ARM Graviton CPU worker path is superseded for RAG.
- The app image is built locally and pushed to ECR; the LLM image is pulled
  from upstream vLLM.
- Daily destroy/apply should target the ephemeral stack only.
- ECR, S3, Qdrant EBS, and LLM cache EBS stay in the persistent stack.
