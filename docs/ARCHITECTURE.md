# Architecture

## How "Ready at Moments Notice" Works

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        BUILD PHASE (infrequent)                              │
│                                                                              │
│  ┌──────────────────┐         ┌──────────────────────────┐                 │
│  │  EC2 Image       │         │  Staging Instance        │                 │
│  │  Builder Pipeline│         │  (c6i.xlarge, CPU-only)  │                 │
│  │                  │         │                          │                 │
│  │  DLAMI base      │         │  Downloads model weights │                 │
│  │  + Docker        │         │  from HuggingFace via    │                 │
│  │  + nvidia-ctk    │         │  Strata setup.py         │                 │
│  │  + Strata image  │         │  → EBS volume (250GB)    │                 │
│  │  = AMI           │         │  → EBS Snapshot          │                 │
│  └──────────────────┘         └────────────┬─────────────┘                 │
│                                             │                                │
│                                             ▼                                │
│                              ┌──────────────────────────┐                   │
│                              │  EBS Fast Snapshot        │                   │
│                              │  Restore (FSR) enabled    │                   │
│                              │  per AZ ($0.75/hr)        │                   │
│                              └────────────┬─────────────┘                   │
└───────────────────────────────────────────┼─────────────────────────────────┘
                                            │
┌───────────────────────────────────────────┼─────────────────────────────────┐
│                   DEPLOY PHASE (frequent)  │                                 │
│                                           ▼                                 │
│  ┌────────────────────────────────────────────────────────────────┐        │
│  │  Launch Instance (g6e.8xlarge)                                  │        │
│  │                                                                  │        │
│  │  Root (30GB):   AMI — Docker + Strata image cached              │        │
│  │  Data (250GB):  FSR snapshot — weights fully available at boot   │        │
│  │                                                                  │        │
│  │  Cloud-init:                                                     │        │
│  │    1. Mount volume           (~2s)                               │        │
│  │    2. GPU check              (~1s)                               │        │
│  │    3. Start container        (~5s, no pull needed)               │        │
│  │    4. Model load + expert cache (~60-90s)                        │        │
│  │    5. /health reports loaded=true  ← SERVING                     │        │
│  │                                                                  │        │
│  │  Total cold→serving time: ~90 seconds                            │        │
│  └────────────────────────────────────────────────────────────────┘        │
│                                                                              │
│  TEARDOWN: Instance terminates → all EBS volumes deleted (ephemeral)         │
│            Snapshot + FSR persist for next launch                            │
└──────────────────────────────────────────────────────────────────────────────┘
```

## Why Not SageMaker or Bedrock

| Constraint | SageMaker | Bedrock | This approach |
|-----------|-----------|---------|---------------|
## Key AWS Services

## Bundled Multi-Volume AMI (Recommended Approach)

The `strata-ami-bundled` module creates a **single AMI whose block device mapping
contains both the software layer AND the model weights**. This eliminates the
separate snapshot management and leverages EBS incremental snapshots for cheap rebuilds.

```
┌─────────────────────────────────────────────────────────────────────────┐
│  Multi-Volume AMI                                                       │
│                                                                          │
│  BDM entry 1: /dev/sda1 → root snapshot (40GB)                          │
│    Contains: OS + NVIDIA driver + Docker + nvidia-ctk + Strata image    │
│                                                                          │
│  BDM entry 2: /dev/sdb → data snapshot (250GB)                          │
│    Contains: Model weights (Qwen GGUF shards, PLE table, MTP layer)     │
│                                                                          │
│  Rebuild for Strata update (new Docker image, new model):               │
│    1. Launch instance from existing AMI (both volumes populated)        │
│    2. docker pull new image / download new model on data volume         │
│    3. aws_ami_from_instance → snapshots both volumes                   │
│    4. Unchanged 250GB of weights = SAME S3 blocks (incremental!)        │
│    5. New AMI costs only the delta (~100-500MB for patches)             │
│                                                                          │
│  Key facts:                                                              │
│    • AMIs are REGION-scoped → automatically available in all AZs        │
│    • EBS snapshots are stored in S3 → replicated across all AZs         │
│    • Incremental snapshots deduplicate unchanged blocks across versions │
│    • FSR pre-warms volume creation per-AZ ($0.75/hr per snapshot×AZ)    │
│    • Production launch: terraform apply → 90s → serving                  │
└─────────────────────────────────────────────────────────────────────────┘
```

### Why Incremental Snapshots Solve the "Don't Re-Download" Problem

EBS snapshots are **block-level incremental**:

- First snapshot of 250GB volume → uploads 250GB to S3 ($12.50/month storage)
- Second snapshot (same volume, only 200MB changed) → uploads 200MB, reuses existing blocks
- Total storage: 250GB + 200MB ≈ 250.2GB (not 500GB!)
- You can rebuild the AMI daily with Docker updates and the weights layer costs the same

This means the "layer" of weights is **never re-downloaded** — it's already in S3
as blocks referenced by every snapshot that includes them.

### Deployment Flow (Bundled AMI)

```
# One-time (per model + per Strata version):
module "bundled_ami" {
  source      = "./modules/strata-ami-bundled"
  model       = "IQ3_XXS"
  subnet_id   = "subnet-abc"
  data_volume_size = 250
}

# Every deploy (minutes, repeatable):
module "strata" {
  source           = "github.com/b1tninja/terraform-aws-strata"
  use_bundled_ami  = true
  ami_id           = module.bundled_ami.ami_id
  instance_type    = "g6e.8xlarge"
  ttl_minutes      = 60
}

# Cleanup:
terraform destroy
```

The production instance gets BOTH volumes from the AMI's BDM — no separate
`weights_snapshot_id` needed, no separate FSR management.



| Service | Role |
|---------|------|
| **EC2 Image Builder** | Build AMI with drivers + Docker + pre-pulled Strata image |
| **EBS Fast Snapshot Restore** | Volume fully initialized at creation — zero I/O latency penalty |
| **EC2 g5 / g6e** | Ampere and Ada: compute capability 8.6 / 8.9. Runs the engine fine, but NVFP4 packs execute on the 8-bit path - the FP4 MMA unit exists only on sm_120 |
| **EC2 g7 / g7e** | Blackwell RTX (sm_120), the cards NVFP4 was written for. `g7e.8xlarge` pairs 96 GiB of VRAM with 1900 GiB of local NVMe; `g7.8xlarge` is the cheapest way to get an FP4-capable box |
| **EC2 p5 / p6** (Hopper, datacenter Blackwell) | The engine ships packages for sm_75/80/86/89/120 only, so sm_90 and sm_100 exit before loading anything. The catalogue rejects these at plan time rather than after an expensive restore |
| **SSM Parameter Store** | Store latest AMI ID + per-model snapshot IDs for CI/CD lookup |
| **OIDC + IAM Roles** | GitHub Actions → AWS auth without long-lived secrets |

## Boot Hooks

The boot script has one extension point, so serving behaviour can grow without touching
the core module or the shared script: `boot_hooks` is an ordered list of shell fragments
that the script splices in **after** the model reports healthy.

```
[1/6] mount volume  [2/6] prerequisites  [3/6] API key  [4/6] pull image
[5/6] start container  [6/6] wait for /health  ──►  boot hooks, in order
```

The contract a hook may rely on, documented in the script itself: it runs as root with
`$DATA_MOUNT`, `$DATA_DEVICE`, `$MODEL`, `$MODEL_FAMILY`, `$PORT`, `$REGION`,
`$HEALTH_TIMEOUT` and `wait_loaded()` in scope, and with `set -euo pipefail` active, so a
failing hook aborts the boot. Hooks must not redefine those names, and must not print step
numbers of their own.

A hook is opaque text, so Terraform cannot type-check it against the script. That gap is
closed by `tests/boot_hooks`, which asserts the shipped hook keeps to the contract: it
still verifies its pinned digest, still records `user_args`, still restarts the container
once, does not redefine base names, and does not invent step labels.

The shipped hook is `modules/strata-control-vector`: it fetches a pinned control vector,
verifies its SHA-256, records the engine arguments as `user_args` plus
`sampling.experimental_speed_projection` in the model's run config, and restarts the
container once so the engine starts with the vector loaded. After that a caller chooses the
behaviour per request, so one endpoint serves the model as published and the projected
configuration. See [examples/nvfp4-uncensored](../examples/nvfp4-uncensored).

Why a hook re-applies on every boot rather than once: the container regenerates the run
settings when the card assignment changes (`docker/entrypoint.sh:206-216`) and tuning
rewrites them, so anything recorded there is provisional until the next boot re-asserts it.
This is also why the weights manifest deliberately ignores `install/`.

## Data Flow

1. Weights downloaded once via `strata launch` onto an EBS volume
2. Volume snapshotted — the golden reference
3. FSR enabled on snapshot × each target AZ
4. On launch, block device mapping references the FSR snapshot
5. Volume appears at `/dev/nvme1n1` with all blocks ready (no lazy load)
6. Cloud-init mounts `/data`, starts Docker container (`-v /data:/data`)
7. Strata sees model files with `.done` markers → skips download
8. Engine loads weights into RAM/VRAM tiers → serving in ~90s

## Failure Modes & Mitigations

| Failure | Mitigation |
|---------|-----------|
| FSR credits exhausted (quota: 5/region) | Provisioned Rate fallback (300 MiB/s ≈ 11 min) |
| Spot interruption | TTL-based relaunch; FSR makes next instance equally fast |
| AMI stale (new Strata release) | Weekly rebuild workflow + `strata_image_tag` variable |
| Corrupted weights on a volume | Sizes verified against the seeded manifest at every boot (`verify_weights`; `full` re-hashes), before the container starts. The download itself is checked by Strata's installer, which pins a SHA-256 per file |
| Snapshot that no longer matches | `sha256sum` digests recorded in `.strata-manifest/files.txt` when the snapshot is built, so drift is detectable rather than assumed |
| AZ capacity unavailable | Change `availability_zone` variable + re-enable FSR in new AZ |

| Multi-tier expert offload (GPU+CPU+RAM+SSD) | No | No | Yes |
| AVX-512 CPU kernels concurrent with GPU | No | No | Yes |
| Pinned memory (mlock) for all 24K experts | Constrained | No | Yes |
| Custom C++/CUDA engine (not vLLM) | Constrained | No | Yes |
| 524K context with RoPE scaling | No | No | Yes |
| Adaptive expert cache at runtime | No | No | Yes |
