###############################################################################
# Identity — must match persistent stack (for name_prefix derivation).
###############################################################################
variable "project" {
  type    = string
  default = "llm-chat"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "region" {
  type    = string
  default = "us-west-2"
}

###############################################################################
# Remote state — where to find the persistent stack outputs.
###############################################################################
variable "persistent_state_bucket" {
  description = "S3 bucket holding the persistent stack tfstate. Defaults to the bootstrap bucket name pattern."
  type        = string
  default     = ""
}

variable "persistent_state_key" {
  description = "S3 key for persistent tfstate"
  type        = string
  default     = "mlops/llm-chat/dev/persistent.tfstate"
}

###############################################################################
# EKS
###############################################################################
variable "eks_version" {
  description = "EKS Kubernetes version. Pick a version currently in standard support to avoid AWS extended-support fees. 1.34 = standard support as of 2026-05."
  type        = string
  default     = "1.34"
}

variable "kubernetes_namespace" {
  description = "Namespace where app pods + Qdrant + vllm-openai live"
  type        = string
  default     = "llm-chat"
}

###############################################################################
# Head node group — x86, hosts Ray head + FastAPI/QA + Embedder + Qdrant.
#
# Rev5 cost-first default: m6i.large (2 vCPU / 8 GiB). Allocatable ~1.8 vCPU is
# TIGHT for the packed pod set (~2.1 vCPU req). To stay within budget:
#   - Embedder num_cpus = 1.0 with intra_op_num_threads = 1
#   - Qdrant request cpu=200m memory=400Mi (MVP scale, ~10 MiB vectors)
#   - FastAPI/QA actor cpu=200m
#   - Ray head cpu=500m
# Sum CPU req ≈ 1.9 vCPU. If pods Pending, bump to m6i.xlarge here (+$8/mo on-
# demand, +$2/mo SPOT) — see doc rev5 §4.2.
###############################################################################
variable "head_instance_types" {
  description = "x86 instance types for the head MNG. Rev5 default = m6i.large (2 vCPU / 8 GiB cost-first). Upgrade to m6i.xlarge if pod packing fails."
  type        = list(string)
  default     = ["m6i.large"]
}

variable "head_capacity_type" {
  description = "ON_DEMAND or SPOT. Head is small and on the critical path; SPOT cheaper but more eviction risk."
  type        = string
  default     = "SPOT"
}

variable "head_min_size" {
  type    = number
  default = 1
}

variable "head_desired_size" {
  type    = number
  default = 1
}

variable "head_max_size" {
  type    = number
  default = 1
}

###############################################################################
# GPU node group — runs vllm-openai. AL2023 NVIDIA AMI for driver preinstall.
#
# Rev5 cost-first default: g4dn.xlarge (T4 16GB, Turing, ~$0.21/h SPOT).
#
# IMPORTANT — T4 limitations vs g5/g6:
#   - NO FP8 KV cache (Turing pre-Ampere). vllm-openai args MUST use
#     --kv-cache-dtype=auto (FP16 KV). Doc rev5 §3.5.x reflects this.
#   - 16 GB VRAM: Qwen2.5-7B AWQ ~5 GB model + FP16 KV needs ~11 GB room.
#     With max_model_len=8192 → KV ~0.5 GiB/seq × 16 seqs = 8 GiB → tight.
#     Recommend max_model_len=4096 + max_num_seqs=8 for T4.
#   - Decode TPS ~3× lower than A10G. Latency budget shifts (see doc §5).
#   - 14B AWQ DOES NOT FIT — 7B only.
#
# For upgraded performance (Ada+, FP8 KV, larger context, 14B), set:
#   gpu_instance_types = ["g6.xlarge", "g5.xlarge"]
###############################################################################
variable "gpu_instance_types" {
  description = "Rev5 default = g4dn.xlarge (T4, cost-first). Upgrade to ['g6.xlarge', 'g5.xlarge'] for FP8 KV + larger context."
  type        = list(string)
  default     = ["g4dn.xlarge"]
}

variable "gpu_capacity_type" {
  description = "SPOT for lab. Flip to ON_DEMAND before high-stakes demo via -var gpu_capacity_type=ON_DEMAND."
  type        = string
  default     = "SPOT"
}

variable "gpu_min_size" {
  type    = number
  default = 0
}

variable "gpu_desired_size" {
  description = "1 GPU node up while cluster is up. Bump to 2 for ChatModel scale-out."
  type        = number
  default     = 1
}

variable "gpu_max_size" {
  type    = number
  default = 2
}

variable "gpu_ami_type" {
  description = "Must be AL2023_x86_64_NVIDIA (or BOTTLEROCKET_x86_64_NVIDIA) so the NVIDIA driver is preinstalled. AL2023_x86_64_STANDARD will NOT advertise nvidia.com/gpu."
  type        = string
  default     = "AL2023_x86_64_NVIDIA"
}

###############################################################################
# NVIDIA device plugin Helm chart
###############################################################################
variable "nvidia_device_plugin_version" {
  description = "Chart version. v0.14.5+ supports K8s 1.28+ and NVIDIA driver 535+."
  type        = string
  default     = "0.14.5"
}

###############################################################################
# Tags
###############################################################################
variable "tags" {
  description = "Extra tags merged with the stack default tags"
  type        = map(string)
  default     = {}
}
