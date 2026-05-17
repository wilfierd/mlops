# 004 — gavinbunney/kubectl_manifest over hashicorp/kubernetes_manifest for CRDs

Status: accepted
Date: 2026-05-15

## Context

The RayService is a CRD (`ray.io/v1`). Terraform has two providers that can
apply arbitrary K8s manifests:

1. `hashicorp/kubernetes` → `kubernetes_manifest` resource. Performs
   server-side dry-run **at plan time**, requires API access at plan time.
   On a fresh `terraform apply` (cluster not yet created), plan fails with
   `cannot create REST client: no client config`.

2. `gavinbunney/kubectl` → `kubectl_manifest` resource. Defers API calls to
   apply time. Works on first-time apply of a brand-new cluster.

The bug with kubernetes_manifest forces a 2-phase apply:
`terraform apply -target=module.eks` first, then `terraform apply`. Awkward
in CI and confusing for new contributors.

## Decision

Use `gavinbunney/kubectl_manifest` for the RayService and all PDBs.
Continue using `hashicorp/kubernetes_namespace` for the namespace (it has
no plan-time dependency).

## Consequences

- One `terraform apply` works from scratch.
- Extra provider in the dependency tree (`gavinbunney/kubectl ~> 1.14`).
- Slightly worse diff output during plan (it shows full YAML body) — manageable.
- If we adopt ArgoCD/Flux later, manifests move out of Terraform entirely
  and this provider goes away.
