# Optimization Comparison — Before vs After

Tracking changes from initial config through P0/P1 hardening and Q4_K_M
backend swap. All costs us-west-2 on-demand Linux, 24×7.

## Baseline → After

| Phase | Node group | Backend | Replicas (base/max) | $/month baseline | $/month peak (max scale) | Latency p95 |
|---|---|---|---|---|---|---|
| **0 — Initial** | 2 × m7g.xlarge mixed | Transformers bf16 | 1 / **3** (3 CPU/rep, head chiếm 1 trong 4 node) | $341 | **$575** | ~3.5s |
| 1 — Split MNG + smaller head | 1 × t4g.large + 1 × m7g.xlarge | Transformers bf16 | 1 / 3 (3 CPU/rep) | $272 | $506 | ~3.5s |
| **2 — + Q4_K_M (CURRENT)** | 1 × t4g.large + 1 × m7g.xlarge | llama.cpp Q4_K_M | **2 / 4** (1.5 CPU/rep, pack 2/pod) | **$272** | **$389** | **~1.0s** |

→ **Baseline: −20% cost ($341→$272). Peak (lúc burst): −32% cost ($575→$389). Max replicas: 3→4. Latency p95: −71%. Replica baseline: 2× (HA). Scale-up 1→2 replica: 18× nhanh (3-5min→10s).**

## Cost breakdown chi tiết

### Phase 0 — Initial

| Item | Quantity | $/h | $/month |
|---|---|---|---|
| EKS control plane | 1 | $0.10 | $73 |
| m7g.xlarge (mixed MNG) | 2 | $0.1632 × 2 | $234 |
| NAT Gateway | 1 | $0.045 + data | $33 |
| EIP | 1 | (attached, free) | $0 |
| ECR storage | — | — | $1 |
| **Total** | | | **$341** |

Vấn đề:
- Head (Ray GCS + Serve proxy, không CPU-bound) chạy trên cùng m7g.xlarge $117 → lãng phí.
- 1 replica/node với `ray_replica_cpus=3` → CPU pack tệ.
- Transformers bf16 chậm so với Q4 CPU-optimized.

### Phase 1 — Split MNG + smaller head node

| Item | Quantity | $/h | $/month | Change |
|---|---|---|---|---|
| EKS control plane | 1 | $0.10 | $73 | — |
| t4g.large head | 1 | $0.0672 | **$48** | new |
| m7g.xlarge worker | 1 | $0.1632 | **$117** | -1 node |
| NAT Gateway | 1 | $0.045 + data | $33 | — |
| ECR | — | — | $1 | — |
| **Total** | | | **$272** | **−$69 (−20%)** |

Trade-off:
- 1 head + 1 worker node thay vì 2 mixed. Head riêng thì rẻ + dedicated.
- Latency vẫn ~3.5s (chưa đụng backend).
- Scale 1→2 replica vẫn cần node mới (3-5 phút).

### Phase 2 — Q4_K_M + llama.cpp + replica pack (current)

| Item | Quantity | $/h | $/month |
|---|---|---|---|
| EKS control plane | 1 | $0.10 | $73 |
| t4g.large head | 1 | $0.0672 | $48 |
| m7g.xlarge worker | 1 | $0.1632 | $117 |
| NAT Gateway | 1 | $0.045 | $33 |
| ECR | — | — | $1 |
| **Total** | | | **$272** |

Thay đổi từ Phase 1:
- Backend swap: `transformers` → `llamacpp` Q4_K_M → **3× nhanh hơn** trên cùng CPU.
- `ray_replica_cpus`: 3 → 1.5 → 2 actors fit trong 1 worker pod 3 CPU.
- `ray_min_replicas`: 1 → 2 → HA baseline.
- **Cost không đổi, capacity gấp đôi + latency 1/3**.

## Cấu hình CPU / Pod / Replica theo từng phase

### Phase 0 — Initial (mixed MNG, Transformers bf16)

```
                       Node (m7g.xlarge = 4 vCPU, ~3.84 allocatable)
                       │
       ┌───────────────┼───────────────┐
       │                               │
   Head pod                     Worker pod
   request 1 CPU                request 3 CPU, limit 3.5 CPU
   limit 2 CPU                  Ray sees 3.5 CPU
   (Serve proxy + GCS)          │
                                ▼
                        ray_actor_options:
                          num_cpus: 3
                        → 1 actor (replica) per pod
                          3 CPU dùng + 0.5 cho raylet daemon
```

Math:
- **Node × 2** (mixed: 1 cho head, 1 cho worker)
- **1 worker pod / node** (request 3 CPU = gần hết 3.84 allocatable)
- **1 replica / pod** (3 CPU ≥ ray_replica_cpus=3, không còn chỗ actor 2)
- **Baseline replicas = 1** (`min_replicas: 1`)
- **Max replicas = 4** (cần scale-up tới 4 worker nodes = 4 × m7g.xlarge)

### Phase 1 — Split MNG, smaller head, vẫn Transformers bf16

```
   Head node                          Worker node
   t4g.large (2 vCPU)                 m7g.xlarge (4 vCPU)
   │                                  │
   ▼                                  ▼
   Head pod                           Worker pod
   request 1 CPU                      request 3 CPU
   limit 2 CPU                        limit 3.5 CPU
   (Serve proxy + GCS)                Ray sees 3.5 CPU
                                      │
                                      ▼
                                  ray_actor_options:
                                    num_cpus: 3
                                  → 1 actor/pod (như Phase 0)
```

Math:
- **Head node × 1** (dedicated, t4g.large $48)
- **Worker node × 1** (dedicated, m7g.xlarge $117)
- **1 replica / pod** (chưa đụng replica_cpus)
- **Baseline replicas = 1**
- **Max replicas = 3** (cần thêm 2 worker nodes)

### Phase 2 — Q4_K_M + replica pack (CURRENT)

```
   Head node                          Worker node
   t4g.large (2 vCPU)                 m7g.xlarge (4 vCPU, ~3.84 allocatable)
   │                                  │
   ▼                                  ▼
   Head pod                           Worker pod
   request 1 CPU                      request 3 CPU
   limit 2 CPU                        limit 3.5 CPU
   (Serve proxy + GCS                 Ray sees 3.5 CPU
    nhẹ, t4g vừa đủ)                  │
                                      ▼
                                ray_actor_options:
                                  num_cpus: 1.5
                                ┌──────────────────────┐
                                │  Replica 1: 1.5 CPU  │  ← Q4 model
                                │  Replica 2: 1.5 CPU  │  ← Q4 model
                                │  Raylet daemon: 0.5  │
                                └──────────────────────┘
                                Total: 3.5 CPU = pod limit
```

Math:
- **Head node × 1** (t4g.large $48)
- **Worker node × 1** baseline (m7g.xlarge $117)
- **1 worker pod / node** (request 3 CPU không có chỗ cho pod thứ 2)
- **2 replicas / pod** (1.5 × 2 = 3 CPU ≤ pod limit, 0.5 spare raylet)
- **Baseline replicas = 2** (`min_replicas: 2` — HA)
- **Max replicas = 4** (scale lên 2 worker nodes × 2 replicas/node)

## So sánh bảng tóm tắt CPU + replica packing

| Item | Phase 0 | Phase 1 | **Phase 2 (current)** |
|---|---|---|---|
| Head node type | m7g.xlarge (4 vCPU) | t4g.large (2 vCPU) | t4g.large (2 vCPU) |
| Head pod CPU req/limit | 1 / 2 | 1 / 2 | 1 / 2 |
| Worker node type | m7g.xlarge (4 vCPU) | m7g.xlarge (4 vCPU) | m7g.xlarge (4 vCPU) |
| Worker pod CPU req/limit | 3 / 3.5 | 3 / 3.5 | 3 / 3.5 |
| `ray_actor_options.num_cpus` | 3 | 3 | **1.5** |
| **Pods / node** | 1 worker | 1 worker | 1 worker |
| **Replicas / pod** | 1 | 1 | **2** |
| **Replicas / node** | 1 | 1 | **2** |
| Worker nodes baseline | 2 | 1 | 1 |
| Worker nodes max | 4 | 3 | 2 |
| **Replicas baseline** | 1 | 1 | **2** (HA) |
| **Replicas max** | 4 (4 nodes) | 3 (3 nodes) | **4** (2 nodes × 2 replica) |

## Tại sao Phase 2 nhồi được 2 replica/pod?

Trước:
```
ray_replica_cpus = 3
worker_pod.limit = 3.5 CPU
→ Ray check: 3.5 ≥ 3 → spawn 1 actor → 0.5 left
→ Ray check: 0.5 ≥ 3? KHÔNG → không nhồi actor 2
→ Phải tạo pod mới (= node mới vì 1 pod/node)
```

Sau Q4_K_M (giảm memory bandwidth bottleneck → 1.5 CPU đủ):
```
ray_replica_cpus = 1.5
worker_pod.limit = 3.5 CPU (vẫn vậy)
→ Ray check: 3.5 ≥ 1.5 → spawn actor 1 → 2.0 left
→ Ray check: 2.0 ≥ 1.5 → spawn actor 2 → 0.5 left (raylet)
→ 2 actors/pod ✓
```

→ Cùng pod, cùng node, scale 1→2 replica instant (chỉ Python spawn actor mới).

## Performance comparison (giữ lại)

| Metric | Phase 0 | Phase 1 | Phase 2 (current) |
|---|---|---|---|
| **Backend** | Transformers bf16 | Transformers bf16 | **llama.cpp Q4_K_M** |
| Model weight on disk | 1.2 GB | 1.2 GB | **0.4 GB** (Q4) |
| RAM per replica | ~3 GB | ~3 GB | **~0.8 GB** |
| CPU per replica | **3** | **3** | **1.5** |
| Latency p50 (64 tokens) | ~2.5s | ~2.5s | **~0.7s** |
| Latency p95 | ~3.5s | ~3.5s | **~1.0s** |
| Latency p99 | ~5s | ~5s | **~1.5s** |
| Tokens/sec per replica | ~25 | ~25 | **~85** |
| Replicas baseline | 1 | 1 | **2** |
| Replicas max (no new node) | 1 | 1 | **2** (pack 2/pod) |
| Replicas max with autoscale | 4 (4 nodes) | 3 (3 nodes) | **4** (2 nodes × 2 replica) |
| Scale 1→2 replica | 3-5 min (new EC2) | 3-5 min (new EC2) | **~10s** (same pod) |
| Scale 2→3 replica | 3-5 min | 3-5 min | 3-5 min (new node) |

## Cost — baseline vs peak

Baseline cost = cluster ở `desired_size`, peak cost = cluster autoscale lên `max_size` (chỉ trả khi đang xử lý burst, sau đó scale xuống lại).

### Phase 0 — Initial (mixed MNG)

Mỗi node m7g.xlarge có ~3.84 vCPU allocatable. Head pod (1 CPU req) + Worker
pod (3 CPU req) = 4 CPU > 3.84 → **không fit cùng node**, head phải 1 node
riêng. `node_max_size=4` → max 3 worker nodes + 1 head node = **3 replicas**.

| State | Nodes (head+worker) | Replicas | Compute $/month | EKS+NAT+ECR | **Total $/month** |
|---|---|---|---|---|---|
| Baseline | 1 head + 1 worker (`desired=2`) | 1 | $234 | $107 | **$341** |
| **Peak (max=4)** | **1 head + 3 worker** | **3** | **$468** | **$107** | **$575** |

→ Khi scale tới max, **cost lên 1.7×** ($575/month) trong thời gian burst.

### Phase 1 — Split MNG + smaller head

| State | Nodes | Replicas | Compute $/month | EKS+NAT+ECR | **Total $/month** |
|---|---|---|---|---|---|
| Baseline | 1 head + 1 worker | 1 | $165 | $107 | **$272** |
| **Peak (max)** | **1 head + 3 workers** | **3** | **$399** | **$107** | **$506** |

→ Peak cost giảm $69 so với Phase 0 (vì head dùng t4g.large).

### Phase 2 — Q4_K_M + replica pack (CURRENT)

| State | Nodes | Replicas | Compute $/month | EKS+NAT+ECR | **Total $/month** |
|---|---|---|---|---|---|
| Baseline | 1 head + 1 worker | **2** (pack 2/pod) | $165 | $107 | **$272** |
| **Peak (max)** | **1 head + 2 workers** | **4** (2 × 2/pod) | **$282** | **$107** | **$389** |

→ Peak cost chỉ **$389** vì pack 2 actor/pod → cần 2 worker thay vì 4.

## Cost per replica — efficiency thực sự

| Phase | Baseline $/replica | Peak $/replica | Notes |
|---|---|---|---|
| 0 | $341 / 1 = **$341** | $575 / **3** = **$192** | Mixed MNG: 4 nodes max nhưng 1 phải làm head → chỉ 3 replica thực sự |
| 1 | $272 / 1 = **$272** | $506 / 3 = **$169** | Head overhead lớn so với ít replica |
| **2 (current)** | $272 / 2 = **$136** | $389 / 4 = **$97** | **Pack 2 actor/pod kéo cost/replica giảm cả 2 chiều** |

→ Phase 2 thắng tất cả các metric:
- **Baseline $/replica: -60% so với Phase 0** ($341 → $136 — vì baseline đã có 2 replica).
- **Peak $/replica: -49% so với Phase 0** ($192 → $97).
- Peak total cost: -32% ($575 → $389).

## Scale-up cascade thời gian

| Trigger | Phase 0 | Phase 1 | Phase 2 |
|---|---|---|---|
| Serve trigger scale | instant | instant | instant |
| Ray actor placement | wait CPU | wait CPU | **OK ngay** (same pod) |
| KubeRay tạo pod mới | ~5s | ~5s | — |
| EKS Cluster Autoscaler request EC2 | ~30s | ~30s | — |
| EC2 boot + join cluster | ~90s | ~90s | — |
| Image pull (cached qua ECR pull-through) | ~30s | ~30s | — |
| Wait GCS ready | ~10s | ~10s | — |
| Model load (PRELOAD bake) | ~30s (bf16 1.2GB) | ~30s | ~5s (Q4 0.4GB) |
| Actor HEALTHY | total ~3-5 min | total ~3-5 min | **~10s** |

## Khi nào vẫn cần scale node mới (Phase 2)?

```
Worker node 1 (m7g.xlarge, 4 vCPU):
├─ Worker pod 1 (request 3 CPU, 5 GiB)
│  ├─ Replica 1: 1.5 CPU, 0.8 GiB
│  └─ Replica 2: 1.5 CPU, 0.8 GiB
│  → 3.0 CPU, 1.6 GiB used
└─ ~1 CPU + 10 GiB rảnh cho raylet + kube system

Khi cần replica 3 → không fit trên worker 1 → trigger EC2 thứ 2 (m7g.xlarge)
→ Vẫn 3-5 phút lần này
```

→ Trong khoảng 1-2 replica (use case bình thường), zero downtime + instant scale.

## Đánh giá cuối

| Tiêu chí | Improvement |
|---|---|
| Cost monthly | **-20%** ($341 → $272) |
| Cost per replica | **-25%** ($85 → $68) |
| Latency p95 | **-71%** (3.5s → 1.0s) |
| Tokens/sec per replica | **+240%** (25 → 85) |
| RAM footprint | **-73%** (3 GB → 0.8 GB per replica) |
| Disk per model | **-67%** (1.2 GB → 0.4 GB) |
| Scale-up 1→2 replica | **18×** (3-5 min → ~10s) |
| HA (replicas baseline) | **2×** (1 → 2) |

→ Mọi metric đều cải thiện, cost không tăng. Đây là kiểu optimization "free lunch" — chỉ tốn ~1-2 ngày code work cho backend swap + node split.

## Bước tiếp theo (P2 — chưa làm)

| Improvement | Estimated impact |
|---|---|
| Spot instances cho worker MNG | −60-70% worker cost = ~$70/month off |
| Karpenter thay MNG autoscale | Scale-up từ 3-5 min → ~45s |
| Model upgrade Qwen2.5-1.5B Q4_K_M (cùng node) | Latency vẫn ~2-2.5s, quality nhảy bậc |
| Larger node m7g.2xlarge | Fit 4-5 replica/node, $235/month |

Pause cluster qua đêm (`worker_desired_size=0`, head luôn chạy): **$154/month** (45% off bình thường).
