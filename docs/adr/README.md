# Architecture Decision Records

One short markdown per non-obvious decision. Numbered monotonically; never
rewrite — supersede instead.

| # | Title | Status |
| --- | --- | --- |
| 001 | [Ray Serve via KubeRay](001-ray-serve-on-kuberay.md) | accepted |
| 002 | [ARM Graviton nodes](002-graviton-arm-nodes.md) | superseded by 006 |
| 003 | [Single-AZ worker placement](003-single-az-workers.md) | accepted |
| 004 | [kubectl_manifest over kubernetes_manifest](004-kubectl-manifest-over-kubernetes-manifest.md) | accepted |
| 005 | [GitHub Actions OIDC, no static AWS keys](005-github-actions-oidc-no-static-keys.md) | accepted |
| 006 | [GPU RAG pivot](006-gpu-rag-pivot.md) | accepted |

## Format

```
# <NN>-<slug>

Status: accepted | superseded by <NN>
Date: YYYY-MM-DD

## Context
2-4 sentences describing the situation forcing a decision.

## Decision
1 sentence: the choice.

## Consequences
Bullets: what becomes true after this decision.
```

## When to write an ADR

- A non-default choice that another engineer would question 6 months later.
- A choice that locks in a vendor / dependency.
- A scope decision (e.g., "skip X for the lab").

What's NOT worth an ADR: tactical fixes, formatting choices, anything the
linter/style guide answers.
