# 002 — ARM Graviton (m7g) over Intel for worker nodes

Status: accepted
Date: 2026-05-15

## Context

Workers run CPU LLM inference (Qwen3-0.6B). Need to pick an instance class.
Options: t3.xlarge (burstable Intel), m6i.xlarge (sustained Intel),
m7g.xlarge (sustained Graviton3 ARM).

Pricing in us-west-2 on-demand Linux (2025):

| Instance | vCPU | RAM | $/h | $/month (24×7) | CPU model |
| --- | --- | --- | --- | --- | --- |
| t3.xlarge | 4 | 16 | $0.1664 | ~$120 | Intel, **burstable** |
| m7g.xlarge | 4 | 16 | $0.1632 | ~$117 | Graviton3 ARM, **sustained** |
| m6i.xlarge | 4 | 16 | $0.1920 | ~$138 | Intel, sustained |

Cost gap between t3 and m7g is tiny (~2%). The real driver is **burstable vs
sustained**. t3 has CPU credits: ~24 credit/h baseline for 4 vCPU. Once
credits drain (sustained CPU load > 30%), t3 either throttles down to
baseline or — if "unlimited" mode is on — charges $0.05/vCPU-h extra. Both
outcomes are bad for LLM inference benchmarking.

We already hit this in early load tests on a local burstable VM (analogous
to t3): p99 latency spiked after ~2 minutes of sustained load.

## Decision

`m7g.xlarge` (Graviton3, sustained CPU). The cost is ~$3/month less than
t3.xlarge but the real win is no credit-throttle risk under sustained load.

## Consequences

- Image must be built for `linux/arm64` (`docker buildx --platform`).
- CI on `ubuntu-latest` (x86) cross-builds via QEMU — ~10x slower than
  native ARM build. Acceptable for lab (~10-15 min per push).
- PyTorch 2.5+ wheels are available for ARM CPU, transformers works fine.
- Avoids t3 credit-throttle issue that crippled earlier load tests.
- If a dependency lacks ARM wheel, fallback is m6i.xlarge (one tfvars edit,
  +$18/month).
