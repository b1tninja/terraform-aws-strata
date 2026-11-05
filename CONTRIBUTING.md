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

`make docs` has to be run with **terraform-docs 0.20.0** — the version `terraform-docs/gh-actions@v1.4.1`
bundles and the version the devcontainer installs. Newer releases format the generated table rules
differently (`| ---- |` instead of `|------|`), so running it with 0.24.0 produces a diff that looks
like whitespace and that `make docs-check` rejects, correctly.

## Releasing a New Version

The registry publishes from git tags, and a few of its requirements are invisible in this repository:

1. The repository must be **public** and named `terraform-<PROVIDER>-<NAME>`. The registry derives
   the consumer address from that name, so this module is `b1tninja/strata/aws` — not
   `b1tninja/terraform-aws-strata`.
2. The **GitHub repository description** becomes the module's short description on the registry. It
   lives in no file, so it has to be set on purpose: `gh repo edit --description "…"`.
3. Tags must be semantic versions, optionally `v`-prefixed (`v0.1.1` and `0.1.1` both work). Tags
   that do not look like versions are ignored, and **at least one tag must exist** before the module
   can be published at all.
4. The first publish is manual: registry.terraform.io → Upload → pick the repository (it lists only
   repositories matching the naming rule). Every release after that is detected by webhook, usually
   inside a minute.

So:

1. Get the default branch green (`make quality` covers the same ground locally).
2. `git tag v0.2.0 && git push origin v0.2.0`
3. Confirm the registry saw it:
   `curl -s https://registry.terraform.io/v1/modules/b1tninja/strata/aws/versions`
4. If it has not appeared after a few minutes, use **Resync Module** under the registry's
   "Manage Module" dropdown — but only then; a resync re-reads every version.

`examples/` and the README address the module through the registry, so the tag they name has to
exist before those configurations will `terraform init`. A `version =` pointing at a tag that was
never pushed fails during init, which is a long way from the line that caused it.

## OpenTofu Compatibility

This module is compatible with both Terraform >= 1.5.0 and OpenTofu >= 1.6.0.
The CI pipeline runs `tofu fmt -check` and `tofu validate` alongside Terraform.

No OpenTofu-specific syntax is needed — the HCL language is identical.
