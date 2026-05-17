# Runbook — LLM Chat on EKS

Operational guide. Assumes the reader has `aws`, `kubectl`, `terraform`, and
`docker`/`podman` configured locally with credentials for the target account.

## Quick reference

| Goal | Command |
| --- | --- |
| Wire kubectl to cluster | `aws eks update-kubeconfig --region us-west-2 --name llm-chat-dev` |
| Open chat UI | `kubectl -n llm-chat port-forward svc/llm-chat-dev-serve-svc 8000:8000` |
| Open Grafana | `kubectl -n monitoring port-forward svc/kube-prom-stack-grafana 3000:80` |
| Get Grafana password | `terraform -chdir=infra/environments/dev output -raw grafana_admin_password` |
| Open Ray dashboard | `kubectl -n llm-chat port-forward svc/llm-chat-dev-head-svc 8265:8265` |
| Tail RayService events | `kubectl -n llm-chat get events --watch` |
| Watch pods | `kubectl -n llm-chat get pods -w` |
| Pause cluster (keep state) | `terraform apply -var node_desired_size=0` |
| Resume | `terraform apply -var node_desired_size=2` |
| Full teardown | `terraform destroy` |

## Day-to-day workflows

### Deploy a code change

1. Edit `app/server.py` (or any source in `app/`).
2. Push to `main` (or open a PR — CI runs but won't deploy).
3. GitHub Actions `deploy.yml` builds image with tag `${SHORT_SHA}`, pushes
   to ECR, applies Terraform with `image_tag=<SHA>`, force-deletes pods.
4. Watch progress: GitHub Actions tab → `deploy` workflow → `terraform apply` job.

After ~5-10 minutes (cold model load), pods become Ready. Confirm:

```bash
kubectl -n llm-chat get pods
kubectl -n llm-chat exec deploy/llm-chat-dev-ray-head -- ray status
```

### Roll back to a previous image

```bash
# 1. Find a previous good tag (ECR keeps last 5 by lifecycle policy)
aws ecr list-images --repository-name llm-chat-dev-ray --region us-west-2

# 2. Apply with that tag
cd infra/environments/dev
terraform apply -var image_tag=<previous-sha>
kubectl -n llm-chat delete pod --all --grace-period=0 --force
```

Or via GitHub UI: Actions → deploy → Run workflow → set image_tag manually
(requires the workflow to be extended to accept an input — current version
uses `$(git rev-parse --short HEAD)`).

### Pause for the night (no cost on compute)

```bash
cd infra/environments/dev
terraform apply -var node_desired_size=0
```

This scales the MNG to zero. EKS control plane still costs ~$0.10/h ($73/month)
and NAT GW ~$0.045/h ($33/month) — about $0.15/h while paused vs $0.50/h
running. To zero everything:

```bash
terraform destroy
```

(Will rebuild bucket-by-bucket on next apply, ~15-20 minutes.)

### Update a model

```bash
# 1. Edit tfvars
sed -i 's|model_id .*|model_id = "Qwen/Qwen2.5-1.5B-Instruct"|' \
  infra/environments/dev/terraform.tfvars

# 2. Apply (only the env-var on Ray pods + manifest changes; no AWS replace)
terraform apply

# 3. Image still needs new model baked in:
ENV=dev ./infra/scripts/push_image.sh
```

If the new model is bigger (>2GB bfloat16), also increase
`worker_memory_request`/`worker_memory_limit` in
`infra/modules/kuberay/variables.tf` defaults, or override per-env.

## Common alerts + remediation

### Alert: pod `CrashLoopBackOff`

```bash
kubectl -n llm-chat describe pod <pod>
kubectl -n llm-chat logs <pod> --previous
```

Triage:
- `pthread_create failed: Resource temporarily unavailable` → PIDs limit on
  the worker EC2 (usually rootless container env). On EKS this should not
  happen — verify with `cat /proc/sys/kernel/pid_max` on the node.
- `Failed to connect to GCS within 5 seconds` → DNS / gRPC c-ares issue.
  Confirm `GRPC_DNS_RESOLVER=native` in pod env: `kubectl exec ... -- env | grep GRPC`.
- `OOMKilled` → bump `worker_memory_limit` in tfvars.

### Alert: pod `ImagePullBackOff`

```bash
kubectl -n llm-chat describe pod <pod>
# look for: ErrImagePull, manifest unknown, denied
```

Common causes:
- ECR repo empty (first apply before `push_image.sh`).
- Tag doesn't exist: `aws ecr list-images --repository-name llm-chat-dev-ray --region us-west-2`.
- Node IAM missing ECR pull → check `kubectl get nodes -o yaml` and confirm
  `aws ecr describe-repositories` works from a node.

### Alert: pod stays `Init:0/1` for >5 min (worker init container)

`wait-gcs-ready` container can't reach head GCS at `<svc>.<ns>.svc.cluster.local:6379`.

```bash
kubectl -n llm-chat logs <worker> -c wait-gcs-ready --tail=20
```

If `Failed to connect to GCS within 5 seconds` repeating:
1. Check head pod is `Running`: `kubectl -n llm-chat get pods -l ray.io/node-type=head`.
2. Verify head svc has endpoints: `kubectl -n llm-chat get endpoints`.
3. Verify the `GRPC_DNS_RESOLVER=native` is set on the init container env.
4. Restart worker: `kubectl -n llm-chat delete pod <worker> --grace-period=0 --force`.

### Alert: Serve replica stuck `PENDING_CREATION`

```bash
kubectl -n llm-chat exec deploy/llm-chat-dev-ray-head -- serve status
```

Message usually says `CPU 3.0 needed, 1.0 available`. Either:
- Wait — Cluster Autoscaler is adding a node (~3 min on AWS).
- Or scale-out won't help → check `max_replicas` and `node_max_size` in tfvars.

### Alert: high p99 latency (Grafana)

1. Grafana → `Ray Serve — LLM Chat` dashboard → `Latency Percentiles`.
2. If p99 > 5x p50 and `Ongoing requests per replica` is high → autoscale
   not catching up. Lower `upscale_delay_s` in `modules/kuberay/locals.tf`
   from 10 to 5.
3. If p50 alone is climbing → CPU saturation on node. Check `CPU per Ray
   Pod` panel; if pinned at limit, bump `worker_cpu_limit` or instance
   class (e.g., `m7g.xlarge` → `m7g.2xlarge`).

### Alert: budget threshold crossed (email)

1. Check `aws ce get-cost-and-usage` filtered by `Project=llm-chat`.
2. Identify top spender (NAT GW, EC2, EKS control plane).
3. Quick saves:
   - Scale MNG to 0 overnight: `terraform apply -var node_desired_size=0`.
   - Reduce `node_max_size` in tfvars to cap worst-case.
   - Tear down between sessions: `terraform destroy`.

## Disaster recovery

Lab is **ephemeral** — no PV, no DB, no user data. To recreate from scratch:

```bash
cd infra/bootstrap && terraform apply        # state bucket + GH OIDC
cd ../environments/dev && terraform apply    # all infra
ENV=dev ./infra/scripts/push_image.sh         # image
```

The S3 state bucket itself is also TF-managed; in catastrophic loss
(account closure), bootstrap is re-applied first. There's no state-of-state
backup — at lab scale that's acceptable.

## Useful one-liners

```bash
# Show all pod resources at a glance
kubectl -n llm-chat get pods -o wide

# Live event tail
kubectl -n llm-chat get events --sort-by='.lastTimestamp' --watch

# Curl chat from inside a pod (network isolated)
kubectl -n llm-chat run debug --rm -i --restart=Never --image=curlimages/curl -- \
  curl -s http://llm-chat-dev-serve-svc:8000/chat \
  -H 'content-type: application/json' \
  -d '{"messages":[{"role":"user","content":"hi"}]}'

# Force re-deploy with same image (no rebuild)
kubectl -n llm-chat delete pod --all --grace-period=0 --force

# Check Ray cluster resources
kubectl -n llm-chat exec deploy/llm-chat-dev-ray-head -- ray status

# List Ray Serve apps
kubectl -n llm-chat exec deploy/llm-chat-dev-ray-head -- serve status
```

## Contact

- Repo: https://github.com/<org>/<repo>
- Owner: see `Owner` tag on any resource (`kubectl describe`).
- Reviewer DevOps: ping in PR.
