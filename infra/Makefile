.PHONY: help init plan apply destroy fmt validate output push roll \
        persistent-init persistent-plan persistent-apply persistent-output \
        cluster-up cluster-down cluster-status cluster-output \
        qdrant-up qdrant-down qdrant-logs qdrant-pf qdrant-status qdrant-init \
        kuberay-up rag-up rag-down rag-logs rag-pf embed-bench

# ENV defaults to dev. ENV_DIR can be overridden to point at persistent/
# or ephemeral/ sub-stacks via STACK=persistent|ephemeral|"".
ENV   ?= dev
STACK ?=
ENV_DIR := environments/$(ENV)$(if $(STACK),/$(STACK),)

# Namespace where app pods live (used by `roll`, `cluster-status`).
NS ?= llm-chat

help: ## list targets
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z_-]+:.*##/ { printf "\033[36m%-18s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

###############################################################################
# Generic plumbing — works for any stack via STACK=persistent|ephemeral or
# a flat ENV path. Example:
#   make plan STACK=persistent
#   make apply STACK=ephemeral
###############################################################################
init: ## terraform init (STACK=persistent|ephemeral)
	terraform -chdir=$(ENV_DIR) init

plan: ## terraform plan
	terraform -chdir=$(ENV_DIR) plan

apply: ## terraform apply -auto-approve (require STACK=persistent|ephemeral)
ifeq ($(strip $(STACK)),)
	$(error STACK is required. Use STACK=persistent or STACK=ephemeral. For routine cluster lifecycle use `make cluster-up`.)
endif
	terraform -chdir=$(ENV_DIR) apply -auto-approve

destroy: ## terraform destroy -auto-approve (require STACK=persistent|ephemeral; persistent is also guarded by prevent_destroy)
ifeq ($(strip $(STACK)),)
	$(error STACK is required. Use STACK=ephemeral for cluster teardown (or prefer `make cluster-down`). `make destroy STACK=persistent` is intentionally awkward — it will still be blocked by prevent_destroy on critical resources.)
endif
	terraform -chdir=$(ENV_DIR) destroy -auto-approve

fmt: ## terraform fmt -recursive across whole infra/
	terraform fmt -recursive

validate: ## terraform validate in $(ENV_DIR)
	terraform -chdir=$(ENV_DIR) validate

output: ## terraform output -json
	terraform -chdir=$(ENV_DIR) output -json

###############################################################################
# Persistent stack — bring up once.
###############################################################################
persistent-init: ## terraform init persistent stack
	$(MAKE) init STACK=persistent

persistent-plan: ## terraform plan persistent stack
	$(MAKE) plan STACK=persistent

persistent-apply: ## terraform apply persistent stack (create VPC/ECR/S3/EBS/OIDC, runs once)
	$(MAKE) apply STACK=persistent

persistent-output: ## show persistent outputs
	$(MAKE) output STACK=persistent

###############################################################################
# Ephemeral stack — cluster lifecycle, run every dev session.
###############################################################################
cluster-up: ## bring up EKS + node groups + addons + PV binds (~12–15 min)
	@echo "==> Applying ephemeral stack..."
	terraform -chdir=environments/$(ENV)/ephemeral apply -auto-approve
	@echo "==> Updating kubeconfig..."
	@CMD=$$(terraform -chdir=environments/$(ENV)/ephemeral output -raw kubeconfig_command); eval "$$CMD"
	@echo "==> Waiting for nodes..."
	@kubectl wait --for=condition=Ready nodes --all --timeout=300s
	@echo "==> Cluster ready. GPU check:"
	@kubectl get nodes -L node-type,nvidia.com/gpu

cluster-down: ## destroy ephemeral stack (EBS data preserved in persistent)
	@echo "==> Snapshotting Qdrant (best effort)..."
	-@kubectl -n $(NS) exec qdrant-0 -- curl -sX POST localhost:6333/collections/documents/snapshots 2>/dev/null || true
	@echo "==> Destroying ephemeral stack..."
	terraform -chdir=environments/$(ENV)/ephemeral destroy -auto-approve
	@echo "==> Cluster destroyed. EBS qdrant + llm-cache retained for next cluster-up."

cluster-status: ## show node + pod summary
	@aws eks list-clusters --region $$(terraform -chdir=environments/$(ENV)/persistent output -raw region 2>/dev/null || echo us-west-2) 2>/dev/null | jq -r .clusters[]
	@echo "--- Nodes ---"
	@kubectl get nodes -L node-type,nvidia.com/gpu 2>/dev/null || echo "(no cluster running)"
	@echo "--- Pods in $(NS) ---"
	@kubectl get pods -n $(NS) 2>/dev/null || true

cluster-output: ## show ephemeral outputs
	$(MAKE) output STACK=ephemeral

###############################################################################
# Image + app workflow (against running cluster).
###############################################################################
push: ## build + push app image to ECR + roll pods
	ENV=$(ENV) ./scripts/push_image.sh

roll: ## force-delete pods so the latest image is pulled
	kubectl -n $(NS) delete pod --all --grace-period=0 --force

###############################################################################
# P2 — vllm-openai server (deploy + smoke bench).
###############################################################################
.PHONY: vllm-up vllm-down vllm-logs vllm-pf vllm-bench

VLLM_MANIFEST := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))/../k8s/vllm-server.yaml

vllm-up: ## deploy vllm-openai StatefulSet + Service (cost-first T4 profile)
	kubectl apply -f "$(VLLM_MANIFEST)"
	@echo "==> Waiting for vllm-server pod Ready (first model download ~3–5 min)..."
	kubectl -n $(NS) wait --for=condition=Ready pod/vllm-server-0 --timeout=900s
	@echo "==> Ready. Port-forward then bench:"
	@echo "    make vllm-pf &     # 'make vllm-pf' blocks; & to background"
	@echo "    make vllm-bench"

vllm-down: ## delete vllm-openai (keeps llm-cache PVC + EBS data)
	kubectl delete -f "$(VLLM_MANIFEST)" --ignore-not-found

vllm-logs: ## tail vllm-server logs
	kubectl -n $(NS) logs -f vllm-server-0

vllm-pf: ## port-forward 8000:8000 to vllm-server (blocking)
	kubectl -n $(NS) port-forward svc/vllm-server 8000:8000

vllm-bench: ## run scripts/bench_vllm.py against localhost:8000 (port-forward first)
	python3 ../scripts/bench_vllm.py \
		--concurrency 1,4 \
		--requests 10 \
		--prompt-tokens 3000 \
		--new-tokens 200 \
		--out ../reports/p2-vllm-bench.md

###############################################################################
# P3 — Qdrant collocate on head node.
###############################################################################
.PHONY: qdrant-up qdrant-down qdrant-logs qdrant-pf qdrant-status

QDRANT_MANIFEST := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))/../k8s/qdrant.yaml

qdrant-up: ## deploy Qdrant StatefulSet + headless Service + init collection schema
	kubectl apply -f "$(QDRANT_MANIFEST)"
	@echo "==> Waiting for qdrant-0 Ready..."
	kubectl -n $(NS) wait --for=condition=Ready pod/qdrant-0 --timeout=120s
	@echo "==> Init 'documents' collection schema (idempotent)..."
	$(MAKE) qdrant-init
	@echo "==> Done. Port-forward to inspect:"
	@echo "    make qdrant-pf &"
	@echo "    curl -s http://localhost:6333/collections"

qdrant-down: ## delete Qdrant StatefulSet + Service (keeps qdrant-data-pvc + EBS data)
	kubectl delete -f "$(QDRANT_MANIFEST)" --ignore-not-found

qdrant-logs: ## tail qdrant-0 logs
	kubectl -n $(NS) logs -f qdrant-0

qdrant-pf: ## port-forward 6333:6333 + 6334:6334 to qdrant-0 (blocking)
	kubectl -n $(NS) port-forward pod/qdrant-0 6333:6333 6334:6334

qdrant-init: ## create/verify 'documents' collection schema (idempotent; opens temp port-forward)
	@PF_LOG=$$(mktemp); \
	 kubectl -n $(NS) port-forward pod/qdrant-0 6333:6333 >"$$PF_LOG" 2>&1 & PF_PID=$$!; \
	 trap 'kill $$PF_PID 2>/dev/null || true; rm -f "$$PF_LOG"' EXIT; \
	 READY=0; \
	 for _ in $$(seq 1 30); do \
	   if curl -sf http://localhost:6333/collections >/dev/null 2>&1; then READY=1; break; fi; \
	   if ! kill -0 $$PF_PID 2>/dev/null; then cat "$$PF_LOG"; exit 1; fi; \
	   sleep 1; \
	 done; \
	 if [ "$$READY" != "1" ]; then cat "$$PF_LOG"; exit 1; fi; \
	 python3 ../scripts/qdrant_init.py; RC=$$?; \
	 exit $$RC

qdrant-status: ## show Qdrant pod + PVC + collection stats (requires port-forward)
	@echo "--- Pod ---"
	@kubectl -n $(NS) get pod qdrant-0 -o wide 2>/dev/null || echo "(not deployed)"
	@echo "--- PVC ---"
	@kubectl -n $(NS) get pvc qdrant-data-pvc 2>/dev/null || echo "(no pvc)"
	@echo "--- PV ---"
	@kubectl get pv qdrant-data-pv 2>/dev/null || echo "(no pv)"
	@echo "--- Collections (needs port-forward on :6333) ---"
	@curl -sf http://localhost:6333/collections 2>/dev/null | python3 -m json.tool || echo "(port-forward not running)"

###############################################################################
# P4 — RAG API + CPU Embedder on Ray head.
###############################################################################
.PHONY: kuberay-up rag-up rag-down rag-logs rag-pf embed-bench

KUBERAY_VERSION ?= 1.6.1
RAG_MANIFEST := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))/../k8s/rayservice.yaml

kuberay-up: ## install/upgrade KubeRay operator (required by rag-up)
	helm upgrade --install kuberay-operator kuberay-operator \
		--repo https://ray-project.github.io/kuberay-helm/ \
		--version $(KUBERAY_VERSION) \
		--namespace kuberay-system \
		--create-namespace

rag-up: kuberay-up ## deploy RayService for RAG API + Embedder (run 'make push' first)
	@IMAGE_TAG=$${IMAGE_TAG:-$$(git -C .. rev-parse --short HEAD 2>/dev/null || echo dev)}; \
	 ECR_URL=$$(terraform -chdir=environments/$(ENV)/persistent output -raw ecr_app_url 2>/dev/null); \
	 [ -n "$$ECR_URL" ] || { echo "ERROR: could not read ecr_app_url from persistent stack — run 'make persistent-apply' first"; exit 1; }; \
	 S3_BUCKET=$$(terraform -chdir=environments/$(ENV)/persistent output -raw data_bucket 2>/dev/null); \
	 [ -n "$$S3_BUCKET" ] || { echo "ERROR: could not read data_bucket from persistent stack"; exit 1; }; \
	 APP_IMAGE=$${APP_IMAGE:-$$ECR_URL:$$IMAGE_TAG}; \
	 REPO_NAME=$$(echo "$$ECR_URL" | sed 's|.*/||'); \
	 REGION=$$(terraform -chdir=environments/$(ENV)/persistent output -raw region 2>/dev/null || echo us-west-2); \
	 aws ecr describe-images --repository-name "$$REPO_NAME" \
	   --image-ids "imageTag=$$IMAGE_TAG" \
	   --region "$$REGION" > /dev/null 2>&1 \
	   || { echo "ERROR: $$APP_IMAGE not found in ECR — run 'make push' first"; exit 1; }; \
	 echo "==> Applying RAG RayService with image $$APP_IMAGE (bucket=$$S3_BUCKET)"; \
	 sed "s|__APP_IMAGE__|$$APP_IMAGE|g; s|__S3_BUCKET__|$$S3_BUCKET|g" "$(RAG_MANIFEST)" | kubectl apply -f -
	@echo "==> Monitor startup:"
	@echo "    kubectl -n $(NS) get rayservice,pods -w"
	@echo "==> Then port-forward and bench:"
	@echo "    make -C infra rag-pf"
	@echo "    make -C infra embed-bench"

rag-down: ## delete app RayService (keeps Qdrant/vLLM/data)
	kubectl -n $(NS) delete rayservice llm-chat --ignore-not-found

rag-logs: ## tail Ray head logs for the RAG app
	kubectl -n $(NS) logs -f -l ray.io/cluster=llm-chat,ray.io/node-type=head -c ray-head --tail=200

rag-pf: ## port-forward 8000:8000 to RAG API (blocking)
	kubectl -n $(NS) port-forward svc/llm-chat-serve-svc 8000:8000

embed-bench: ## run /embed smoke benchmark (requires rag-pf)
	python3 ../scripts/bench_embedder.py \
		--base-url http://localhost:8000 \
		--batches 1,32 \
		--requests 20
