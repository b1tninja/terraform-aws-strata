# terraform-aws-strata

Deploy [Strata](https://github.com/Niko1221/Strata) on AWS EC2 GPU instances with **instant cold-start** — from zero to serving in ~90 seconds.

## What This Does

Strata runs massive MoE models (Qwen3.8-Flash-Next, DeepSeek V4.1) by distributing 24,576 experts across GPU VRAM, system RAM, and SSD. This Terraform module:

1. **Pre-bakes model weights** into an EBS snapshot
2. **Enables EBS Fast Snapshot Restore** so volumes are fully initialized at creation (no lazy loading)
3. **Bakes the Strata Docker image** into a custom AMI (no pull at boot)
4. **Launches ephemeral GPU instances** that are serving within ~90 seconds

```
terraform apply → wait 90s → POST /v1/chat/completions → terraform destroy
```

## One model, two configurations

The routed experts are the expensive part: `NVFP4` is 128 GB of weights. Whether the
model declines your requests or not is decided by a **267,552-byte** control vector that
the engine applies while loading them, so the same weights, the same volume, the same
snapshot and the same image serve two configurations. The difference is one boolean:

```hcl
module "strata" {
  source        = "github.com/b1tninja/terraform-aws-strata"
  instance_type = "g7e.8xlarge"   # sm_120: FP4 tensor cores
  model         = "NVFP4"
  model_family  = "nvfp4"

  uncensored    = true            # 261 KiB of steering, not a second 128 GB model
}
```

`/v1/models` then reports `strata-nvfp4-nvfp4-uncensored` instead of
`strata-nvfp4-nvfp4`. Nothing is re-downloaded: the instance fetches the vector from a
pinned commit, verifies its SHA-256, records it as `user_args` in the model's run config
— the one documented channel that survives the engine rewriting that file — and restarts
the container once, costing about a minute of extra boot time.

| | stock | uncensored |
|---|---|---|
| weights | 128 GB | *the same* 128 GB |
| extra bytes | — | **261 KiB** |
| served name | `strata-nvfp4-nvfp4` | `strata-nvfp4-nvfp4-uncensored` |

Plan fails unless the pack is the NVFP4 GPTQ one the vector was measured on **and** its
licence permits it: NVIDIA's `NVFP4-NVIDIA` / `NVFP4-QAD` packs are refused, exactly as
strata-launcher refuses them. Walkthrough:
[`examples/nvfp4-uncensored`](examples/nvfp4-uncensored); for both configurations at once
from a single snapshot, [`examples/one-snapshot-two-configs`](examples/one-snapshot-two-configs).

## Quick Start

```hcl
module "strata" {
  source = "github.com/b1tninja/terraform-aws-strata"

  instance_type    = "g6e.8xlarge"
  model            = "IQ3_XXS"
  model_family     = "qwen"
  weights_snapshot_id = "snap-0abc123def456"  # pre-created
  ami_id           = "ami-0abc123def456"      # pre-built
  associate_public_ip = true
  allowed_cidr_blocks = ["203.0.113.0/32"]    # your IP
  ttl_minutes      = 60                        # auto-terminate

  tags = { Environment = "dev" }
}
```

## Prerequisites (one-time setup)

| Step | Tool | Frequency |
|------|------|-----------|
| Build the AMI | `modules/strata-ami` or `.github/workflows/build-ami.yml` | On Strata release |
| Create weights snapshot | `modules/strata-data-snapshot` or `.github/workflows/refresh-weights.yml` | Per model |

After that, every deployment is just `terraform apply` → ready in 90s.

## Supported Instances

Published engine packages contain code for **sm_75, sm_80, sm_86, sm_89 and sm_120**
only, so the biggest AWS GPUs are not the safest choice — an unsupported card exits
before loading a model.

| Family | GPU | Compute Capability | Status |
|--------|-----|-------------------|--------|
| `g7e.*` | NVIDIA RTX PRO 6000 Blackwell (96GB) | 12.0 | ✅ Best for NVFP4 (FP4 tensor cores) |
| `g7.*` | NVIDIA RTX PRO 4500 Blackwell (32GB) | 12.0 | ✅ FP4, cheapest spot price |
| `g6e.*` | NVIDIA L40S (48GB) | 8.9 (Ada) | ✅ Recommended for the Qwen quants |
| `g6.*` | NVIDIA L4 (24GB) | 8.9 (Ada) | ✅ Works |
| `g5.*` | NVIDIA A10G (24GB) | 8.6 (Ampere) | ✅ Works |
| `p5.*` `p5e.*` `p5en.*` | H100 / H200 | 9.0 (Hopper) | ❌ No engine package |
| [nvfp4-uncensored](examples/nvfp4-uncensored) | Same weights + control vector | The second configuration of one model |
| [one-snapshot-two-configs](examples/one-snapshot-two-configs) | Two endpoints, one weights snapshot | Both configurations side by side |

| `p6-b200.*` `p6-b300.*` `p6e-gb200.*` | B200 / B300 / GB200 | 10.x | ❌ No engine package |
| `g5g.*` | Graviton + GPU | arm64 | ❌ Images are x86-64, need AVX2 |

Set `model` and `instance_type`; `data_volume_size` derives from the model
automatically, and a combination that cannot work fails at `terraform plan`
(`modules/strata-catalog`, asserted in `tests/catalog`).

See [docs/MODELS.md](docs/MODELS.md) for model → instance mapping.

## Repository Structure

```
terraform-aws-strata/
├── main.tf                  # Root module (instance + networking + IAM)
├── variables.tf             # All configuration options
├── outputs.tf               # Endpoint, IPs, IDs
├── versions.tf              # Provider constraints
├── modules/
│   ├── strata-ami/          # EC2 Image Builder pipeline
│   ├── strata-data-snapshot/ # Weights volume → snapshot → FSR
│   └── strata-instance/     # Standalone instance module
├── examples/
│   ├── ephemeral-on-demand/ # Simplest: deploy + destroy
│   ├── spot-fleet/          # Cost-optimized with spot
│   └── full-pipeline/       # Build everything from scratch
├── .github/workflows/
│   ├── build-ami.yml        # Rebuild AMI (weekly/manual)
│   ├── refresh-weights.yml  # Download model → snapshot → FSR
│   ├── deploy-ephemeral.yml # Deploy → test → report
│   └── benchmark.yml        # Deploy → benchmark → upload
├── scripts/
│   ├── wait-healthy.sh      # Poll /health until loaded
│   └── teardown.sh          # Safe destroy wrapper
└── docs/
    ├── ARCHITECTURE.md      # How it works, why not SageMaker
    ├── COST.md              # Pricing scenarios
    └── MODELS.md            # Model → instance mapping
```

## GitHub Actions

All workflows use OIDC (no stored AWS keys). Configure:
- `secrets.AWS_ROLE_ARN` — IAM role with EC2/EBS/Image Builder permissions
- `vars.BUILD_SUBNET_ID` / `vars.STAGING_SUBNET_ID` — subnet for build instances

## Security & Lifecycle

| Flag | Effect |
|------|--------|
| `use_secrets_manager` | Keeps the API key out of user_data. The instance fetches it at boot from Secrets Manager using its instance profile (IMDSv2 + `secretsmanager:GetSecretValue`). |
| `secrets_manager_secret_id` | Reuse an existing secret (name or ARN) instead of creating one. Leave empty and Terraform creates `<name_prefix>/api-key/<model>` holding JSON with an `api_key` field. |
| `use_eventbridge_scheduler` | Terminate the instance when the TTL expires via EventBridge Scheduler, which still fires if the instance is wedged. Set `ttl_minutes = 0` to disable. |

The key is never written to the boot log, the process list, or `docker inspect` — it
reaches the container through a `0600` `--env-file`. To read it back:

```bash
terraform output api_key
```

## Why Not SageMaker / Bedrock

Strata's architecture needs:
- All 24K experts pinned in RAM with `mlock`
- AVX-512 CPU kernels running simultaneously with CUDA
- SSD streaming for the 28.8GB n-gram table
- Adaptive expert cache that learns during inference
- Custom C++/CUDA engine (not a Python inference framework)

None of which managed inference platforms support. Raw EC2 gives full hardware control.

## License

MIT — see [LICENSE](LICENSE). Model weights are governed by their respective licenses (Qwen, DeepSeek, etc.).

## Inputs and Outputs

<!-- BEGIN_TERRAFORM_DOCS -->
<!-- This section is auto-generated by terraform-docs. -->
<!-- Run `make docs` to regenerate after changing variables/outputs. -->
<!-- END_TERRAFORM_DOCS -->

## Development

```bash
# Using the devcontainer (recommended):
# Open in VS Code → "Reopen in Container"

# Or locally:
make quality       # fmt + validate + lint + security + docs
make help          # List all targets
```

Requires: `terraform` (or `tofu`), `tflint`, `trivy`, `terraform-docs`.
