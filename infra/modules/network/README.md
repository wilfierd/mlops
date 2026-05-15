# network

Thin wrapper around `terraform-aws-modules/vpc/aws v5`. Creates a VPC with:

- 2 public subnets, one per AZ (`worker_az`, `extra_az`) — required because the
  EKS control plane needs subnets in >=2 AZ.
- 2 private subnets, one per AZ. Only the `worker_az` private subnet is wired
  to a NAT gateway and intended for worker nodes; `worker_subnet_ids` exposes
  exactly that one subnet so callers can place a single-AZ MNG there.
- 1 NAT gateway (`single_nat_gateway = true`) — cheapest layout for demo / dev.

Tags every subnet with `kubernetes.io/cluster/${cluster_name} = shared` plus
`role/elb` (public) and `role/internal-elb` (private) so EKS-aware controllers
(AWS LB Controller, etc.) can discover them.

## Inputs

| Name | Type | Description |
| --- | --- | --- |
| `name_prefix` | string | Resource name prefix |
| `cluster_name` | string | EKS cluster name (drives `kubernetes.io/cluster/<name>` subnet tag) |
| `vpc_cidr` | string | VPC CIDR, e.g. `10.40.0.0/16` |
| `worker_az` | string | AZ where workers live |
| `extra_az` | string | Second AZ required by EKS control plane |
| `tags` | map(string) | Tags applied to every resource |

## Outputs

| Name | Description |
| --- | --- |
| `vpc_id` | VPC id |
| `vpc_cidr` | VPC CIDR |
| `control_plane_subnet_ids` | Subnets to pass to EKS (2 AZ) |
| `worker_subnet_ids` | Subnet to pass to the worker MNG (single AZ) |
| `public_subnet_ids` | All public subnets |
| `private_subnet_ids` | All private subnets |
