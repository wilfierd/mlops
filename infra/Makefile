.PHONY: help init plan apply destroy fmt validate output push roll \
        persistent-init persistent-plan persistent-apply persistent-output \
        cluster-up cluster-down cluster-status cluster-output

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
