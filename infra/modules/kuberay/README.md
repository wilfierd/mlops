# kuberay

Installs the KubeRay operator via Helm and applies the single `llm-chat`
`RayService` for the RAG API + ONNX embedder deployment.

The RayService manifest is applied with `kubectl_manifest` (from
`gavinbunney/kubectl`) instead of `kubernetes_manifest` — `kubectl_manifest`
does not require API access at plan time, so a fresh `terraform apply` against
a brand-new EKS cluster works in one shot.

## File layout

Terraform loads every `*.tf` in this directory, so the split is purely for
readability — not a runtime concern.

| File | What's in it |
| --- | --- |
| `main.tf` | Namespace + `helm_release.kuberay_operator` |
| `locals.tf` | `local.common_env` + `local.rayservice` (manifest body) |
| `rayservice.tf` | `kubectl_manifest.rayservice` that applies the CR |
| `pdb.tf` | PodDisruptionBudget for the singleton Ray head |
| `variables.tf`, `outputs.tf`, `versions.tf` | as usual |

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `service_name` | string | `llm-chat` | RayService metadata.name |
| `namespace` | string | `llm-chat` | App namespace |
| `operator_namespace` | string | `kuberay-system` | Operator namespace |
| `operator_chart_version` | string | `1.6.1` | kuberay-operator Helm chart |
| `ray_version` | string | `2.55.1` | Ray runtime version |
| `image` | string | — | Container image (full ECR URL + tag) |
| `head_*` | string | see code | Head container resource requests/limits |

## Outputs

| Name | Description |
| --- | --- |
| `namespace` | App namespace |
| `operator_namespace` | Operator namespace |
| `service_name` | K8s Service name exposing the Serve HTTP port |

## Notes

- `GRPC_DNS_RESOLVER=native` is wired into the Ray head pod to work around the
  c-ares + CoreDNS handshake bug that can bite Ray on fresh pods.
- `imagePullPolicy: IfNotPresent` — once the node has pulled the image once,
  it doesn't pull again on every app restart with the same tag.
