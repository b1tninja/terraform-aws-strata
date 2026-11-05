# Contributing to terraform-aws-strata

## Quick Start

```bash
# With devcontainer (recommended):
# Open repo in VS Code → Ctrl+Shift+P → "Reopen in Container"

# Manual:
make init      # terraform init for all modules
make quality   # fmt-check + validate + lint + security
```

## Naming Convention

This repo follows the [Terraform Registry naming convention](https://developer.hashicorp.com/terraform/registry/modules/publish):

```
terraform-<PROVIDER>-<NAME>
```

The repo (and local folder) are named `terraform-aws-strata` so the module can be published to the Terraform Registry directly.

## Commit Convention

We use [conventional commits](https://www.conventionalcommits.org/):

```
feat: new feature
fix: bug fix
docs: documentation
chore: housekeeping
refactor: code restructure
test: adding tests
```

## Module Structure

```
modules/
  <module-name>/
    main.tf           # Primary resources
    variables.tf      # Input variables
    outputs.tf        # Outputs
    versions.tf       # Required providers
    scripts/          # Templates, scripts (.tpl files)
```

## Running Checks Locally

| Tool | Command | What it checks |
|------|---------|----------------|
| terraform fmt | `make fmt` | Canonical formatting |
| terraform validate | `make validate` | Syntax + references |
| tflint | `make lint` | Best practices + AWS rules |
| trivy | `make security` | Misconfigurations |
| terraform-docs | `make docs` | README auto-generation |
| OpenTofu | `make tofu-validate` | Drop-in TF compatibility |

All at once: `make quality`

## Releasing a New Version

1. Ensure `main` branch is green (CI passes).
2. Tag a semver release: `git tag v0.2.0 && git push --tags`
3. If published to the Terraform Registry, it auto-detects the new tag.

## OpenTofu Compatibility

This module is compatible with both Terraform >= 1.5.0 and OpenTofu >= 1.6.0.
The CI pipeline runs `tofu fmt -check` and `tofu validate` alongside Terraform.

No OpenTofu-specific syntax is needed — the HCL language is identical.
