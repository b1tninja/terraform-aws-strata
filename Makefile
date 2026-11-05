# strata-terraform Makefile
# All targets work inside the devcontainer or locally with tools installed.

.PHONY: help init validate test-all catalog-test fmt fmt-check lint docs docs-check security quality tofu-validate clean

TF ?= terraform
TOFU ?= tofu
TFLINT ?= tflint
DOCS ?= terraform-docs
TRIVY ?= trivy

# Directory lists are derived, never typed out. Three separate hand-maintained lists had
# already drifted: init covered 5 modules and 3 examples while validate covered 7 modules and
# 7 examples, so "make init && make validate" failed on a fresh clone with "Module not
# installed" - and the same staleness hid a failing assertion in a test directory nobody had
# initialised, because nothing ever initialised it. The rule that stays true as the repository
# grows is "any directory holding Terraform configuration". It is checked against *.tf rather
# than main.tf so a suite split across files, or one without a main.tf, is not silently
# skipped; today the two predicates agree on the same 19 directories (modules/backend is empty,
# and examples/layered-stacks holds only a README, so both are correctly left out).
CONFIG_DIRS := $(sort $(dir $(wildcard modules/*/*.tf) $(wildcard examples/*/*.tf) \
  $(wildcard examples/*/*/*.tf) $(wildcard tests/*/*.tf)))
TEST_DIRS := $(sort $(dir $(wildcard tests/*/*.tf)))

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-18s\033[0m %s\n", $$1, $$2}'

init: ## terraform init (root + every configuration found in the tree)
	$(TF) init -backend=false
	@for d in $(CONFIG_DIRS); do \
	  echo "-- init $$d"; \
	  $(TF) -chdir=$$d init -backend=false || exit 1; \
	done

fmt: ## Format all Terraform files
	$(TF) fmt -recursive

fmt-check: ## Check formatting (non-destructive)
	$(TF) fmt -recursive -check

validate: ## Validate root + every configuration found in the tree
	$(TF) validate
	@for d in $(CONFIG_DIRS); do \
	  echo "-- validate $$d"; \
	  $(TF) -chdir=$$d validate || exit 1; \
	done

test-all: ## Run every plan-time assertion suite (no AWS creds)
	@for d in $(TEST_DIRS); do \
	  echo "-- plan $$d"; \
	  $(TF) -chdir=$$d plan -no-color || exit 1; \
	done

catalog-test: test-all ## Deprecated alias for test-all; the suites outgrew the name

lint: ## Run tflint on all modules
	$(TFLINT) --init
	$(TFLINT) --recursive

docs: ## Write the generated inputs/outputs section into README
	$(DOCS) . --config .terraform-docs.yml

docs-check: ## Verify that section is current, without writing anything
	$(DOCS) . --config .terraform-docs.yml --output-mode verify

security: ## Trivy IaC misconfiguration scan
	$(TRIVY) config --scanners misconfig --severity HIGH,CRITICAL .

tofu-validate: ## Validate with OpenTofu (drop-in replacement)
	$(TOFU) init -backend=false && $(TOFU) validate

# docs-check rather than docs: a quality gate that rewrites README is a gate that makes the
# tree dirty while judging it, and the difference between the two was invisible while docs
# only printed to stdout.
quality: fmt-check validate lint security docs-check test-all ## Run all quality checks

clean: ## Remove .terraform directories (lock files are kept: they are committed for root modules)
	find . -name .terraform -type d -exec rm -rf {} + 2>/dev/null || true
	find . -name '*.tfstate*' -delete 2>/dev/null || true
