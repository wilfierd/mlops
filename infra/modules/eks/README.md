# eks

Thin wrapper around `terraform-aws-modules/eks/aws v20`. Provisions:

- EKS cluster (`var.kubernetes_version`) with both public + private API endpoint.
- IRSA-ready (the upstream module wires the OIDC provider).
- Core addons (`coredns`, `kube-proxy`, `vpc-cni`) on `most_recent`.
- Managed node groups defined by `var.node_groups` (a map so callers can add
  spot pools, gpu pools, etc. without changing the module).
- Optional extra ECR pull permission scoped to `var.extra_ecr_repository_arns`.

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `name` | string | — | Cluster name |
| `kubernetes_version` | string | `1.30` | EKS K8s version |
| `vpc_id` | string | — | VPC id |
| `control_plane_subnet_ids` | list(string) | — | Subnets for the control plane (>=2 AZ) |
| `node_subnet_ids` | list(string) | — | Subnets for the MNGs |
| `node_groups` | map(object) | — | See type signature below |
| `extra_ecr_repository_arns` | list(string) | `[]` | Repos nodes can pull from |
| `tags` | map(string) | `{}` | Tags applied to every resource |

`node_groups` entry shape:

```hcl
{
  instance_types = list(string)
  capacity_type  = optional(string, "ON_DEMAND")  # or "SPOT"
  min_size       = number
  desired_size   = number
  max_size       = number
  labels         = optional(map(string), {})
  taints         = optional(list(object({ key = string, value = string, effect = string })), [])
}
```

## Outputs

| Name | Description |
| --- | --- |
| `cluster_name` | EKS cluster name |
| `cluster_endpoint` | K8s API endpoint |
| `cluster_ca_data` | Base64-encoded cluster CA |
| `cluster_oidc_provider_arn` | OIDC provider ARN (for IRSA roles) |
| `cluster_oidc_provider_url` | OIDC issuer URL |
| `node_iam_role_arns` | Map of node group name -> IAM role ARN |
