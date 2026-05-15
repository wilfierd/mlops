.PHONY: help init plan apply destroy fmt validate output push roll

ENV ?= dev
ENV_DIR := environments/$(ENV)

help: ## list targets
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z_-]+:.*##/ { printf "\033[36m%-12s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

init: ## terraform init in environments/$(ENV)
	terraform -chdir=$(ENV_DIR) init

plan: ## terraform plan
	terraform -chdir=$(ENV_DIR) plan

apply: ## terraform apply -auto-approve
	terraform -chdir=$(ENV_DIR) apply -auto-approve

destroy: ## terraform destroy -auto-approve
	terraform -chdir=$(ENV_DIR) destroy -auto-approve

fmt: ## terraform fmt -recursive
	terraform fmt -recursive

validate: ## terraform validate in environments/$(ENV)
	terraform -chdir=$(ENV_DIR) validate

output: ## terraform output
	terraform -chdir=$(ENV_DIR) output

push: ## build + push image to ECR + roll pods
	ENV=$(ENV) ./scripts/push_image.sh

roll: ## force-delete pods so the latest image is pulled
	kubectl -n llm-chat delete pod --all --grace-period=0 --force
