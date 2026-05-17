# 002 — ARM Graviton (m7g) over Intel for worker nodes

Status: accepted
Date: 2026-05-15

## Context

Workers run CPU LLM inference (Qwen3-0.6B). Need to pick an instance class.
Options: t3.xlarge (burstable Intel), m6i.xlarge (sustained Intel),
m7g.xlarge (sustained Graviton3 ARM).

Pricing in us-west-2:

| Instance | vCPU | RAM | $/h |
| --- | --- | --- | --- |
| t3.xlarge | 4 | 16 | 0.166 |
| m6i.xlarge | 4 | 16 | 0.192 |
| m7g.xlarge | 4 | 16 | 0.154 |

## Decision

`m7g.xlarge` (Graviton3, sustained CPU, 25% cheaper than m6i, no
burstable-credit risk under load test).

## Consequences

- Image must be built for `linux/arm64` (`docker buildx --platform`).
- CI on `ubuntu-latest` (x86) cross-builds via QEMU — ~10x slower than
  native ARM build. Acceptable for lab (~10-15 min per push).
- PyTorch 2.5+ wheels are available for ARM CPU, transformers works fine.
- Avoids t3 credit-throttle issue that crippled earlier load tests.
- If a dependency lacks ARM wheel, fallback is m6i.xlarge (one tfvars edit).
