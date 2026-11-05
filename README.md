# terraform-aws-strata

Deploy [Strata](https://github.com/Niko1221/Strata) on AWS EC2 GPU instances with **instant cold-start** — from zero to serving in ~90 seconds.

## What This Does

Strata runs massive MoE models (Qwen3.8-Flash-Next, DeepSeek V4.1) by distributing 24,576 experts across GPU VRAM, system RAM, and SSD. This Terraform module:

1. **Pre-bakes model weights** into an EBS snapshot
2. **Enables EBS Fast Snapshot Restore** so volumes are fully initialized at creation (no lazy loading)
3. **Bakes the Strata Docker image** into a custom AMI (no pull at boot)
4. **Launches ephemeral GPU instances** that are serving within ~90 seconds
5. **Validates your choice against the model and instance catalogue** at plan time, so an
   instance the engine has no build for, or a volume too small for the pack, fails before
   anything is rented
6. **Composes serving behaviour through boot hooks**: the shipped `strata-control-vector`
   module loads a refusal-direction projection so one endpoint serves the model as
   published *and* steered, chosen per request, for 267,552 bytes rather than a second
   128 GB download

```
terraform apply → wait 90s → POST /v1/chat/completions → terraform destroy
```

## One model, two behaviours

The routed experts are the expensive part: `NVFP4` is 128 GB of weights. Whether the
model declines your requests or not is decided by a **267,552-byte** control vector that
the engine applies while loading them, so the same weights, the same volume, the same
snapshot and the same image serve two behaviours. The difference is one boot hook:

```hcl
module "steer" {
  source       = "./modules/strata-control-vector"
  model        = "NVFP4"
  model_family = "nvfp4"
}

module "strata" {
  source        = "github.com/b1tninja/terraform-aws-strata"
  instance_type = "g7e.8xlarge"   # sm_120: FP4 tensor cores
  model         = "NVFP4"
  model_family  = "nvfp4"

  boot_hooks    = [module.steer.boot_hook]   # 261 KiB of steering, not a second 128 GB model
}
```

The vector must be loaded when the engine starts, so the hook restarts the container once
(about a minute). After that **one endpoint serves both behaviours**, chosen per request:
the engine reads `sampling.experimental_speed_projection` and sends it `cvec=0|1`, and
with the projection off a request is token for token the stock model's. Nothing is
re-downloaded, and `user_args` is the channel used because it is the one documented field
that survives the engine rewriting the rest of the run config.

| | stock | projected |
|---|---|---|
| weights | 128 GB | *the same* 128 GB |
| container | **the same process** | *the same process* |
| extra bytes | none | **261 KiB** |
| chosen by | default | `"experimental_speed_projection": true` per request |

Three vocabularies describe this mechanism, and the module uses the engine's: **control
vector** (`--control-vector-scaled`) implementing a **refusal-direction projection**,
which this engine calls **experimental speed projection** (`cvec=0|1`); the fork that
publishes the vector and the Windows launcher call the result **uncensored**. It is not
OrcaRouter-style *abliteration*, which edits the weights.

Two gates run at plan time. **Lineage:** the vector is one direction in
Qwen3.8-Flash-Next's activation space, so it applies to packs derived from those weights -
upstream measured it on `qwen-nvfp4-gptq`, ISTA's Q2_0 and IQ2_XS, and Unsloth's
UD-Q4_K_XL, "works unchanged on all three quants, with no rescaling" - but not to Swift 1.5
or the Coder, which are other weights. **Licence:** NVIDIA's `NVFP4-NVIDIA` / `NVFP4-QAD`
quants are refused because the NVIDIA Open Model License does not allow bypassing the
model's safety guardrails, which is a permission limit rather than a technical one.
Walkthrough: [`examples/nvfp4-uncensored`](examples/nvfp4-uncensored); for isolated
endpoints sharing one snapshot,
[`examples/one-snapshot-two-configs`](examples/one-snapshot-two-configs); for serving
policies as separate states, [`examples/layered-stacks`](examples/layered-stacks).

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
| [nvfp4-uncensored](examples/nvfp4-uncensored) | Same weights + control vector | Two behaviours from one endpoint, per request |
| [one-snapshot-two-configs](examples/one-snapshot-two-configs) | Two endpoints, one weights snapshot | Isolation without duplicating model bytes |
| [layered-stacks](examples/layered-stacks) | Base stack owns the snapshot, second stack owns the policy | Serving policies as separate states |

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

## Where the money goes

Only one stage of this pipeline needs a GPU, so only that stage should be paying GPU rates.
Prices are spot/on-demand hourly for Linux, read from the catalogue on 2026-11-04 for
us-east-1; instance prices you do not see here were not verified and should be checked in
your account.

| Stage | Needs a card? | Runs on | Note |
|---|---|---|---|
| Build the AMI (Docker + `docker pull`) | **No** | `c6i.2xlarge` | the CUDA stack comes from the Deep Learning base AMI, selected by data source; the build steps only install and pull |
| Download and convert weights, write the manifest | **No** | `c6i.xlarge`, `use_spot` optional | long and network-bound; spot is cheaper but a reclamation restarts the download, so leave it off for the one run that must finish |
| First boot: load, tune, validate a hook | **Yes** | `g7.8xlarge` spot **$0.768/hr** | same sm_120 engine path as `g7e`, experts just spill to RAM; plumbing is what you are proving here, not throughput |
| Promote that volume to a snapshot | No | no instance at all | `modules/strata-volume-snapshot`; tuning lives on the volume (`/data/state`), so this is what stops every later instance re-tuning |
| Serve | **Yes** | `g7e.8xlarge` spot **$3.190/hr**, on-demand $5.268 | NVFP4 on 96 GiB of VRAM; `g7.8xlarge` (32 GiB) is the cheap way to get an FP4-capable box |

Three levers beyond instance choice:

- **Idle cost dominates.** `ttl_minutes` plus the EventBridge scheduler terminate the
  instance at TTL expiry; a forgotten `g7e` costs more in a day than the whole pipeline.
- **Fast Snapshot Restore is a standing charge** per enabled availability zone while it is
  on, not per use. `enable_fsr` exists on both snapshot paths; turn it on to launch and off
  when you stop. Provisioned rate for volume initialization is the pay-per-create
  alternative (AWS illustrates it at roughly $0.0036 per GB of snapshot at 300 MB/s,
  region-dependent) if you only restore occasionally.
- **Volumes are cheap, hours are not.** gp3 is $0.08 per GB-month with 3,000 IOPS included,
  so keeping several model snapshots is a rounding error next to one wasted GPU hour.

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
