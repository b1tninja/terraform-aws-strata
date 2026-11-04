# strata-terraform Makefile
# All targets work inside the devcontainer or locally with tools installed.

.PHONY: help init fmt validate lint docs security quality test-all tofu-validate clean

TF ?= terraform
TOFU ?= tofu
TFLINT ?= tflint
DOCS ?= terraform-docs
TRIVY ?= trivy

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-18s\033[0m %s\n", $$1, $$2}'

init: ## terraform init (all modules + examples)
	$(TF) init -backend=false
	cd modules/strata-ami && $(TF) init -backend=false
	cd modules/strata-ami-bundled && $(TF) init -backend=false
	cd modules/strata-data-snapshot && $(TF) init -backend=false
	cd modules/strata-instance && $(TF) init -backend=false
	cd examples/ephemeral-on-demand && $(TF) init -backend=false
	cd examples/spot-fleet && $(TF) init -backend=false
	cd examples/full-pipeline && $(TF) init -backend=false

fmt: ## Format all Terraform files
	$(TF) fmt -recursive

fmt-check: ## Check formatting (non-destructive)
	$(TF) fmt -recursive -check

validate: ## Validate all modules and examples
	$(TF) validate
	cd modules/strata-ami && $(TF) validate
	cd modules/strata-ami-bundled && $(TF) validate
	cd modules/strata-data-snapshot && $(TF) validate
	cd modules/strata-instance && $(TF) validate
	cd examples/ephemeral-on-demand && $(TF) validate
	cd examples/spot-fleet && $(TF) validate
	cd examples/full-pipeline && $(TF) validate

lint: ## Run tflint on all modules
	$(TFLINT) --init
	$(TFLINT) --recursive

docs: ## Generate README terraform-docs section
	$(DOCS) . --config .terraform-docs.yml

security: ## Trivy IaC misconfiguration scan
	$(TRIVY) config --scanners misconfig --severity HIGH,CRITICAL .

tofu-validate: ## Validate with OpenTofu (drop-in replacement)
	$(TOFU) init -backend=false && $(TOFU) validate

quality: fmt-check validate lint security docs ## Run all quality checks

clean: ## Remove .terraform directories and state files
	find . -name .terraform -type d -exec rm -rf {} + 2>/dev/null || true
	find . -name .terraform.lock.hcl -delete 2>/dev/null || true
	find . -name '*.tfstate*' -delete 2>/dev/null || true
