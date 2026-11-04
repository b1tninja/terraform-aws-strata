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

| Service | Role |
|---------|------|
| **EC2 Image Builder** | Build AMI with drivers + Docker + pre-pulled Strata image |
| **EBS Fast Snapshot Restore** | Volume fully initialized at creation — zero I/O latency penalty |
| **EC2 G6e / G5** | GPU instances, compute capability 8.6/8.9 (Strata CUDA compatible) |
| **SSM Parameter Store** | Store latest AMI ID + per-model snapshot IDs for CI/CD lookup |
| **OIDC + IAM Roles** | GitHub Actions → AWS auth without long-lived secrets |

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
| Corrupted model on snapshot | SHA-256 check in boot script before starting |
| AZ capacity unavailable | Change `availability_zone` variable + re-enable FSR in new AZ |

| Multi-tier expert offload (GPU+CPU+RAM+SSD) | No | No | Yes |
| AVX-512 CPU kernels concurrent with GPU | No | No | Yes |
| Pinned memory (mlock) for all 24K experts | Constrained | No | Yes |
| Custom C++/CUDA engine (not vLLM) | Constrained | No | Yes |
| 524K context with RoPE scaling | No | No | Yes |
| Adaptive expert cache at runtime | No | No | Yes |
