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

`boot_hooks` is one of two splice points in the boot script. The other, `pre_start_hooks`, runs
before the container exists - the last moment a layer can still change what `/data` points at -
which is how `modules/strata-instance-store` serves the pack from the instance's local NVMe.
Both are opaque text and the contracts differ, so `tests/boot_disk` asserts each splice lands on
the right side of `docker run` and of the `wait_loaded()` definition.

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
│   ├── strata-ami/             # EC2 Image Builder pipeline
│   ├── strata-ami-bundled/     # AMI with the weights volume baked in
│   ├── strata-catalog/         # Model/instance facts checked at plan time
│   ├── strata-control-vector/  # Boot hook: refusal-direction projection
│   ├── strata-data-snapshot/   # Weights volume → snapshot → FSR
│   ├── strata-instance/        # Standalone instance module
│   ├── strata-instance-store/  # Pre-start hook: serve from local NVMe
│   └── strata-volume-snapshot/ # Promote tuned state into the golden snapshot
├── examples/
│   ├── ephemeral-on-demand/    # Simplest: deploy + destroy
│   ├── spot-fleet/             # Cost-optimized with spot
│   ├── full-pipeline/          # Build everything from scratch
│   ├── nvfp4-uncensored/       # One model, two behaviours, per request
│   ├── one-snapshot-two-configs/ # Same volume, different serving settings
│   └── layered-stacks/         # base + uncensored as separate states
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

<!-- BEGIN_TF_DOCS -->
## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_allowed_cidr_blocks"></a> [allowed\_cidr\_blocks](#input\_allowed\_cidr\_blocks) | CIDR blocks allowed to access the Strata API port | `list(string)` | <pre>[<br/>  "0.0.0.0/0"<br/>]</pre> | no |
| <a name="input_ami_id"></a> [ami\_id](#input\_ami\_id) | Pre-built AMI ID with Strata baked in. If empty, uses the latest Deep Learning AMI and installs on first boot. | `string` | `""` | no |
| <a name="input_api_key"></a> [api\_key](#input\_api\_key) | API key for the Strata server. Auto-generated if empty. | `string` | `""` | no |
| <a name="input_associate_public_ip"></a> [associate\_public\_ip](#input\_associate\_public\_ip) | Whether to associate a public IP address | `bool` | `true` | no |
| <a name="input_boot_hooks"></a> [boot\_hooks](#input\_boot\_hooks) | Shell fragments to splice into the boot script, in order, after the model reports<br/>healthy. This is the extension point: the core module deliberately knows nothing<br/>about what a hook does, so new serving behaviour arrives as a module rather than as<br/>another input here. They are called hooks rather than layers because a control<br/>vector already owns the word "layer" in this project.<br/><br/>Contract offered to a hook: it runs as root with $DATA\_MOUNT, $DATA\_DEVICE, $MODEL,<br/>$MODEL\_FAMILY, $PORT, $REGION, $HEALTH\_TIMEOUT and wait\_loaded() in scope, and with<br/>set -euo pipefail active, so a failing hook aborts the boot. A hook is opaque text<br/>and Terraform cannot check it against the script, so tests/boot\_hooks asserts the<br/>contract for whatever ships in this repository.<br/><br/>The shipped hook loads a control vector so one model serves two behaviours:<br/>  boot\_hooks = [module.steer.boot\_hook]   # see modules/strata-control-vector | `list(string)` | `[]` | no |
| <a name="input_bundled_data_volume_device"></a> [bundled\_data\_volume\_device](#input\_bundled\_data\_volume\_device) | Device name the AMI's data volume maps to (from the AMI's block device mapping) | `string` | `"/dev/sdb"` | no |
| <a name="input_context_length"></a> [context\_length](#input\_context\_length) | Maximum context window (32k, 64k, 128k, 256k, or a number) | `string` | `"128k"` | no |
| <a name="input_data_volume_size"></a> [data\_volume\_size](#input\_data\_volume\_size) | Size of the /data volume in GiB. When unset it is derived from the model's download size plus headroom (see modules/strata-catalog). | `number` | `null` | no |
| <a name="input_enable_fast_snapshot_restore"></a> [enable\_fast\_snapshot\_restore](#input\_enable\_fast\_snapshot\_restore) | Enable EBS Fast Snapshot Restore on the weights volume for instant initialization | `bool` | `true` | no |
| <a name="input_extra_env"></a> [extra\_env](#input\_extra\_env) | Additional environment variables to pass to the Strata container | `map(string)` | `{}` | no |
| <a name="input_gpu_roles"></a> [gpu\_roles](#input\_gpu\_roles) | A role per card instead of a card list: "1=main,0=helper", roles being main, helper<br/>or off, and unnamed cards off. Mutually exclusive with gpus.<br/><br/>Prefer this on multi-card instances: the roles are written into the run settings at<br/>every start, so nothing saved has to be dropped the way gpus does (docs/DOCKER.md:124,<br/>docker/entrypoint.sh:218-224). | `string` | `""` | no |
| <a name="input_gpus"></a> [gpus](#input\_gpus) | Which cards the engine may use, as the monitor numbers them: "0" or "0,1". Empty means<br/>the engine's choice.<br/><br/>Two things follow from setting it. On a volume whose model is already set up, the<br/>container deletes the saved run settings when they name a different card and lets setup<br/>write them again from the files present (docker/entrypoint.sh:206-216; the weights are<br/>kept). That also drops anything a boot hook recorded in the run config, which is why<br/>hooks re-apply on every boot rather than once. And it cannot be combined with<br/>gpu\_roles, which the container treats as a hard error (:222). | `string` | `""` | no |
| <a name="input_health_check_timeout_seconds"></a> [health\_check\_timeout\_seconds](#input\_health\_check\_timeout\_seconds) | Max seconds to wait for the model to finish loading before giving up | `number` | `600` | no |
| <a name="input_instance_type"></a> [instance\_type](#input\_instance\_type) | EC2 instance type. See docs/MODELS.md for recommendations per model. | `string` | `"g6e.8xlarge"` | no |
| <a name="input_key_pair_name"></a> [key\_pair\_name](#input\_key\_pair\_name) | EC2 key pair name for SSH access (optional) | `string` | `""` | no |
| <a name="input_kv_quantization"></a> [kv\_quantization](#input\_kv\_quantization) | KV cache quantization (int8, q4\_0, k8v4, fp16) | `string` | `"int8"` | no |
| <a name="input_min_driver_version"></a> [min\_driver\_version](#input\_min\_driver\_version) | Fail the boot if the instance's NVIDIA driver is older than this, e.g. "570.00". Empty (the<br/>default) means the boot logs the driver version it found and carries on.<br/><br/>Worth setting once measured, because a driver older than the image tag's CUDA build does not<br/>fail at plan time: the container starts, the engine reports an insufficient driver version, and<br/>the instance bills while it does. No default is imposed here - NVIDIA's CUDA-to-driver table<br/>was not confirmable from the environment this module was written in, and a guessed floor would<br/>fail deployments that work fine. | `string` | `""` | no |
| <a name="input_model"></a> [model](#input\_model) | Strata model identifier (e.g. IQ3\_XXS, Q2\_0, IQ2\_XS, UD-Q6\_K\_XL, NVFP4). The catalog in modules/strata-catalog lists every accepted value and derives the volume size from it. | `string` | `"IQ3_XXS"` | no |
| <a name="input_model_family"></a> [model\_family](#input\_model\_family) | Model family: qwen, swift, coder, unsloth, gyro, nvfp4 or deepseek41 | `string` | `"qwen"` | no |
| <a name="input_name_prefix"></a> [name\_prefix](#input\_name\_prefix) | Prefix for all resource names | `string` | `"strata"` | no |
| <a name="input_parallel"></a> [parallel](#input\_parallel) | Requests answered at the same time, 1 to 8. Leave unset and the container fits it to<br/>the card, which is the right answer almost always: this is a routed model whose decode<br/>is bound by card bandwidth, so more concurrency mostly costs memory. | `number` | `null` | no |
| <a name="input_pre_start_hooks"></a> [pre\_start\_hooks](#input\_pre\_start\_hooks) | Shell fragments spliced into the boot script before the container starts, for layers that<br/>change what /data points at rather than how the model serves - a weights copy on local<br/>NVMe, say. The contract is narrower than boot\_hooks: wait\_loaded() does not exist yet<br/>because nothing is serving, and set -euo pipefail is active, so a hook that fails aborts<br/>the boot. An optimisation hook should therefore run its body in a subshell that relaxes<br/>errexit and ends true; modules/strata-instance-store does exactly that.<br/><br/>  pre\_start\_hooks = [module.scratch.pre\_start\_hook]   # see modules/strata-instance-store | `list(string)` | `[]` | no |
| <a name="input_provisioned_iops"></a> [provisioned\_iops](#input\_provisioned\_iops) | EBS gp3 provisioned IOPS for the data volume | `number` | `16000` | no |
| <a name="input_provisioned_throughput"></a> [provisioned\_throughput](#input\_provisioned\_throughput) | EBS gp3 provisioned throughput in MiB/s for the data volume | `number` | `1000` | no |
| <a name="input_region"></a> [region](#input\_region) | AWS region to deploy in | `string` | `"us-east-1"` | no |
| <a name="input_secrets_manager_secret_id"></a> [secrets\_manager\_secret\_id](#input\_secrets\_manager\_secret\_id) | Pre-existing Secrets Manager secret ID or ARN (JSON with api\_key field). Overrides auto-generation. | `string` | `""` | no |
| <a name="input_spot_max_price"></a> [spot\_max\_price](#input\_spot\_max\_price) | Maximum hourly price for spot instance. Empty = on-demand price. | `string` | `""` | no |
| <a name="input_strata_image_tag"></a> [strata\_image\_tag](#input\_strata\_image\_tag) | Strata Docker image tag to pull, pinned by default. Upstream publishes both moving tags<br/>(latest-cuda13) and pinned ones per backend: <version>-cuda12, -cuda13, -rocm-gfx110x,<br/>-rocm-gfx1151, -rocm-gfx120x, -sycl. List what exists with an anonymous token:<br/>  curl -s "https://ghcr.io/token?scope=repository:niko1221/strata:pull&service=ghcr.io"<br/>  curl -s -H "Authorization: Bearer <token>" https://ghcr.io/v2/niko1221/strata/tags/list<br/><br/>Pinned because a moving tag lets two boots of an unchanged configuration run different engine<br/>builds, and the control-vector layer pins a commit and its engine arguments precisely because<br/>upstream's docs and shipped defaults have disagreed before. Note the images can lag the app<br/>release: Strata 0.2.10 was published as an app release before any 0.2.10 image tag appeared.<br/>Setting a latest-* tag here is allowed and produces a plan-time warning, not an error. | `string` | `"0.2.9-cuda13"` | no |
| <a name="input_strict_catalog"></a> [strict\_catalog](#input\_strict\_catalog) | Fail the plan when model or model\_family is not in modules/strata-catalog. Turn it off to deploy a size the catalog has not been updated for yet. | `bool` | `true` | no |
| <a name="input_subnet_id"></a> [subnet\_id](#input\_subnet\_id) | Subnet ID for the instance. Leave empty to auto-select. | `string` | `""` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Common tags applied to all resources | `map(string)` | `{}` | no |
| <a name="input_ttl_minutes"></a> [ttl\_minutes](#input\_ttl\_minutes) | Auto-terminate the instance after this many minutes (0 = no auto-terminate) | `number` | `0` | no |
| <a name="input_tune_mode"></a> [tune\_mode](#input\_tune\_mode) | How the container tunes the run settings: "quick", "thorough" or "skip". Tuning<br/>happens once and is kept in the preset, so a restart does not tune again; set this to<br/>"skip" to leave whatever tuning the volume already has alone, or pass RETUNE=1 through<br/>extra\_env to force a fresh pass.<br/><br/>The container's own default is "skip"; this module asks for a quick pass on first boot<br/>because an untuned preset is measurably slower and there is nobody at the keyboard. | `string` | `"quick"` | no |
| <a name="input_use_bundled_ami"></a> [use\_bundled\_ami](#input\_use\_bundled\_ami) | If true, the AMI already contains the model weights as a data volume in its block device mapping. No separate weights\_snapshot\_id needed. | `bool` | `false` | no |
| <a name="input_use_eventbridge_scheduler"></a> [use\_eventbridge\_scheduler](#input\_use\_eventbridge\_scheduler) | Use EventBridge Scheduler for reliable TTL termination (survives instance hangs, unlike in-instance shutdown) | `bool` | `true` | no |
| <a name="input_use_secrets_manager"></a> [use\_secrets\_manager](#input\_use\_secrets\_manager) | Store the API key in AWS Secrets Manager (fetched by instance at boot via IAM, not baked into user\_data) | `bool` | `false` | no |
| <a name="input_use_spot"></a> [use\_spot](#input\_use\_spot) | Use spot instances for cost savings (may be interrupted) | `bool` | `false` | no |
| <a name="input_verify_weights"></a> [verify\_weights](#input\_verify\_weights) | How carefully the boot checks the weights volume against the manifest written when the<br/>snapshot was seeded: "off", "sizes" (default) or "full".<br/><br/>"sizes" compares each recorded file size, which costs one stat per file and catches<br/>what actually goes wrong in practice - a truncated or missing file after a restore.<br/>"full" re-hashes every byte against the seeded SHA-256, which is minutes on a 128 GB<br/>pack: worth running once per snapshot, or when an instance behaves oddly, not on every<br/>boot. Either mode fails the boot rather than serving a model that is not whole.<br/><br/>This covers storage after the install. The download itself is verified by Strata's own<br/>installer, which pins a SHA-256 and a size per file (see docs/SAFETY.md upstream), and<br/>a volume with no manifest - one prepared by hand, or an older snapshot - is reported<br/>and booted anyway, because there is nothing to compare it against.<br/><br/>Scope is the model data. The run settings under install/ and everything under state/<br/>are excluded, because they are edited during normal operation - tuning rewrites them,<br/>and a boot hook records engine arguments there - so a manifest that watched them would<br/>fail every boot and only teach people to turn this off. | `string` | `"sizes"` | no |
| <a name="input_vision_mode"></a> [vision\_mode](#input\_vision\_mode) | Vision mode: off, on, gpu, cpu | `string` | `"off"` | no |
| <a name="input_vpc_id"></a> [vpc\_id](#input\_vpc\_id) | VPC ID to deploy into. Leave empty to use the default VPC. | `string` | `""` | no |
| <a name="input_weights_snapshot_id"></a> [weights\_snapshot\_id](#input\_weights\_snapshot\_id) | EBS snapshot ID containing pre-downloaded model weights. If empty, model downloads on first boot (slow). | `string` | `""` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_anthropic_endpoint"></a> [anthropic\_endpoint](#output\_anthropic\_endpoint) | Anthropic-compatible API endpoint URL |
| <a name="output_api_endpoint"></a> [api\_endpoint](#output\_api\_endpoint) | OpenAI-compatible API endpoint URL |
| <a name="output_api_key"></a> [api\_key](#output\_api\_key) | API key for the endpoint (null when it comes from a pre-existing Secrets Manager secret) |
| <a name="output_api_key_secret_arn"></a> [api\_key\_secret\_arn](#output\_api\_key\_secret\_arn) | Secrets Manager ARN holding the API key, when use\_secrets\_manager is enabled |
| <a name="output_boot_hooks"></a> [boot\_hooks](#output\_boot\_hooks) | How many fragments each splice point contributes, and how large each one is |
| <a name="output_catalog_notes"></a> [catalog\_notes](#output\_catalog\_notes) | What the catalog makes of this model/family/instance combination, as a list. Nothing here blocks a deploy; the things that should have failed the plan in preflight.tf. |
| <a name="output_data_volume_id"></a> [data\_volume\_id](#output\_data\_volume\_id) | Data EBS volume ID |
| <a name="output_iam_instance_profile_arn"></a> [iam\_instance\_profile\_arn](#output\_iam\_instance\_profile\_arn) | IAM instance profile ARN |
| <a name="output_instance_id"></a> [instance\_id](#output\_instance\_id) | ID of the running Strata instance |
| <a name="output_launch_template_id"></a> [launch\_template\_id](#output\_launch\_template\_id) | Launch template ID (for external orchestration) |
| <a name="output_private_ip"></a> [private\_ip](#output\_private\_ip) | Private IP address of the instance |
| <a name="output_public_ip"></a> [public\_ip](#output\_public\_ip) | Public IP address of the instance |
| <a name="output_security_group_id"></a> [security\_group\_id](#output\_security\_group\_id) | Security group ID |
| <a name="output_ttl_terminate_schedule_arn"></a> [ttl\_terminate\_schedule\_arn](#output\_ttl\_terminate\_schedule\_arn) | EventBridge Scheduler schedule that terminates the instance at TTL expiry (null when disabled) |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| <a name="module_catalog"></a> [catalog](#module\_catalog) | ./modules/strata-catalog | n/a |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_ebs_fast_snapshot_restore.weights](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ebs_fast_snapshot_restore) | resource |
| [aws_iam_instance_profile.strata](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_instance_profile) | resource |
| [aws_iam_role.scheduler](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.strata_instance](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.scheduler_terminate](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.secrets_access](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.strata_instance](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_instance.strata](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/instance) | resource |
| [aws_instance.strata_spot](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/instance) | resource |
| [aws_launch_template.strata](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/launch_template) | resource |
| [aws_scheduler_schedule.ttl_terminate](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/scheduler_schedule) | resource |
| [aws_secretsmanager_secret.api_key](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret) | resource |
| [aws_secretsmanager_secret_version.api_key](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret_version) | resource |
| [aws_security_group.strata](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_security_group_rule.egress_all](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group_rule) | resource |
| [aws_security_group_rule.ingress_api](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group_rule) | resource |
| [aws_security_group_rule.ingress_ssh](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group_rule) | resource |
| [random_password.api_key](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) | resource |
| [terraform_data.container_knobs](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |
| [terraform_data.preflight](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |
| [terraform_data.verify_weights](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |
| [time_static.deployment](https://registry.terraform.io/providers/hashicorp/time/latest/docs/resources/static) | resource |
| [aws_ami.dlami](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/ami) | data source |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_iam_policy_document.ec2_assume](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |
| [aws_subnet.selected](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/subnet) | data source |
| [aws_subnets.selected](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/subnets) | data source |
| [aws_vpc.default](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/vpc) | data source |
| [aws_vpc.selected](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/vpc) | data source |
<!-- END_TF_DOCS -->

## Development

```bash
# Using the devcontainer (recommended):
# Open in VS Code → "Reopen in Container"

# Or locally:
make quality       # fmt + validate everything + lint + security + docs-check + every test suite
make help          # List all targets
```

Requires: `terraform` (or `tofu`), `tflint`, `trivy`, `terraform-docs`.
