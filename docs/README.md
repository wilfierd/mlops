# Docs

| File | Purpose |
| --- | --- |
| `diagram.py` | Python source for architecture diagrams. Run to regenerate PNGs. |
| `architecture.png` | Top-level AWS architecture (regenerated from `diagram.py`). |
| `request_flow.png` | How a single `/chat` request traverses the stack. |
| `autoscale.png` | The 4-layer autoscale cascade (Serve → Ray → KubeRay → MNG). |
| `runbook.md` | Operational guide: deploy, rollback, pause, common alerts. |
| `adr/` | Architecture Decision Records — one short MD per non-obvious choice. |

## Regenerating diagrams

```bash
python -m venv .venv
source .venv/bin/activate
pip install diagrams

# OS dep: graphviz
# Fedora:   sudo dnf install graphviz
# Ubuntu:   sudo apt-get install graphviz
# macOS:    brew install graphviz

cd docs
python diagram.py
# -> architecture.png, request_flow.png, autoscale.png
```

PNGs are committed so reviewers see them on GitHub without rerunning Python.
CI can be extended to regenerate + assert no diff, but for lab that is
overkill.

## Why diagram-as-code

- **No drift**: diagram lives next to code; updating an architectural
  decision means touching `diagram.py` in the same commit as the TF change.
- **Version controlled**: PR reviewer sees diagram delta inline.
- **Reproducible**: anyone can regen the same image; no proprietary tool.

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
