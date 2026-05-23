# Docs

| File | Purpose |
| --- | --- |
| `rag-technical-design.md` | Current RAG/GPU architecture plan, cost model, and phase checklist. |
| `p2-vllm-runbook.md` | vLLM deployment/runbook notes. |
| `p3-qdrant-runbook.md` | Qdrant deployment/runbook notes. |
| `runbook.md` | Older operations notes; keep as reference until rewritten for RAG. |
| `adr/` | Architecture Decision Records. Older CPU ADRs are kept as history and marked superseded where relevant. |

## ADR convention

ADRs are short. Format:

```
# <NN>-<slug>

Status: accepted | superseded by <NN>
Date: YYYY-MM-DD

## Context
2-4 sentences describing the situation forcing a decision.

## Decision
1 sentence: the choice we made.

## Consequences
Bulleted list: what becomes true after this decision.
```

Number files monotonically: `001-...`, `002-...`. Never rewrite history;
when a decision is reversed, add a new ADR that supersedes the old one.
