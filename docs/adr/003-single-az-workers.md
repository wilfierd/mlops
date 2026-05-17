# 003 — Single-AZ worker placement (vs multi-AZ HA)

Status: accepted
Date: 2026-05-15

## Context

EKS control plane requires subnets in ≥2 AZs. Workers can be placed in any
subset of those AZs. Multi-AZ workers improve availability but cost extra:

- ~$33/month per additional NAT Gateway.
- Cross-AZ data transfer ($0.01/GB) for inter-pod traffic.
- 2-3× the number of EC2 instances at idle (one per AZ baseline).

Lab is for DevOps eval, not user-facing prod — there is no SLA.

## Decision

VPC has 2 AZs (forced by EKS) but worker MNG only schedules in `worker_az`.
`single_nat_gateway = true`. ~$33/month NAT vs $99/month if multi-AZ.

## Consequences

- If the worker AZ goes down, the service is down until manual intervention.
- NAT GW is also a single point of failure for image pull egress.
- Saves ~$66/month vs multi-AZ for the lab lifetime.
- Going multi-AZ later is a single tfvars + module edit:
  `node_subnet_ids = module.network.private_subnet_ids` (all 2 AZ),
  `single_nat_gateway = false`, `one_nat_gateway_per_az = true`.
- Documented in `Prod_ready.md` as Item P1.6 for the non-lab variant.
