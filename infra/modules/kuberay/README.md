# kuberay

Installs the KubeRay operator via Helm and applies a `RayService` for the
chat-app deployment.

The RayService manifest is applied with `kubectl_manifest` (from
`gavinbunney/kubectl`) instead of `kubernetes_manifest` — `kubectl_manifest`
does not require API access at plan time, so a fresh `terraform apply` against
a brand-new EKS cluster works in one shot.

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `service_name` | string | `llm-chat` | RayService metadata.name |
| `namespace` | string | `llm-chat` | App namespace |
| `operator_namespace` | string | `kuberay-system` | Operator namespace |
| `operator_chart_version` | string | `1.6.1` | kuberay-operator Helm chart |
| `ray_version` | string | `2.55.1` | Ray runtime version |
| `image` | string | — | Container image (full ECR URL + tag) |
| `model_id` | string | — | HF model id |
| `model_dtype` | string | `bfloat16` | PyTorch dtype |
| `min_replicas` | number | `1` | Ray Serve min replicas |
| `max_replicas` | number | `3` | Ray Serve max replicas |
| `replica_cpus` | number | `3` | CPU each Ray Serve replica reserves |
| `head_*` | string | see code | Head container resource requests/limits |
| `worker_*` | string | see code | Worker container resource requests/limits |

## Outputs

| Name | Description |
| --- | --- |
| `namespace` | App namespace |
| `operator_namespace` | Operator namespace |
| `service_name` | K8s Service name exposing the Serve HTTP port |

## Notes

- `GRPC_DNS_RESOLVER=native` is wired into both head and worker pods to work
  around the c-ares + CoreDNS handshake bug that bites Ray Serve on fresh
  pods.
- `imagePullPolicy: IfNotPresent` — once the node has pulled the image once,
  it doesn't pull again on every scale-up.
