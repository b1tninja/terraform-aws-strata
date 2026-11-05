# Model → hardware mapping

Numbers here come from `modules/strata-catalog`, which transcribes Strata's own
catalog (`niko1221/strata` `setup.py`, dict `MODELS`) plus AWS's published instance
specs (read 2026-11-04, us-east-1). Change the catalog, not this file, and
`tests/catalog` will tell you when the two disagree.

## Model sizes

| Model | Families | Download GiB | RAM to pin experts GiB | Pictures | Min engine | Licence |
|-------|----------|-------------:|-----------------------:|:--------:|-----------|---------|
| Q2_0 | qwen | 66.4 | 48 | – | 0.1.26 | Qwen |
| IQ2_XS | qwen, swift | 68.0 | 48 | – | 0.1.26 | Qwen |
| IQ3_XXS | qwen, swift | 75.8 | 60 | ✅ | 0.1.26 | Qwen |
| IQ3_S | qwen, swift | 83.6 | 62 | ✅ | 0.1.26 | Qwen |
| IQ1_M | coder | 58.4 | 32 | ✅ | 0.1.26 | Qwen |
| UD-IQ4_XS | unsloth | 93.7 | 48 (budget) | ✅ | 0.1.38 | Qwen |
| UD-Q4_K_XL | unsloth | 111.3 | 48 (budget) | ✅ | 0.1.31 | Qwen |
| UD-Q5_K_XL | unsloth | 158.3 | 108 | ✅ | 0.1.44 | Qwen |
| UD-Q6_K_XL | unsloth | 169.2 | 118 | ✅ | 0.1.44 | Qwen |
| Q8_0 | unsloth | 188.2 | 136 | ✅ | 0.1.38 | Qwen |
| Gyro-S | gyro | 58.5 | 28 (VRAM+RAM) | ✅ | 0.1.45.1 | Qwen |
| Gyro-M | gyro | 92.0 | 35 (VRAM+RAM) | ✅ | 0.1.45.1 | Qwen |
| NVFP4 | nvfp4 | 128.0 | 80 | ✅ | 0.1.44 | **Qwen** |
| NVFP4-NVIDIA | nvfp4 | 128.0 | 80 | ✅ | 0.1.44 | **NVIDIA** |
| NVFP4-QAD | nvfp4 | 102.2 (+110 to convert) | 80 | ✅ | 0.1.45 | **NVIDIA** |
| IST-DAS-1.75bpw | deepseek41 | 239 | ~40 | – | separate package | DeepSeek |
| IST-DAS-2.00bpw | deepseek41 | 257 | ~40 | – | separate package | DeepSeek |
| IST-DAS-2.25bpw | deepseek41 | 274 | ~40 | – | separate package | DeepSeek |
| UD-Q8_K_XL | deepseek41 | 508 | hundreds | – | separate package | DeepSeek |

The DeepSeek figures are the whole footprint: model shards plus the shared 111 GB
Engram n-gram table and the 8 GB DSpark drafter. Its engine is a separate signed
package, not the one in the Strata image.

## Data volume

`data_volume_size` is derived when you leave it unset: download size (plus conversion
space for NVFP4-QAD) + 50 GiB headroom, rounded up to the next 10 GiB. Set it
explicitly only to go bigger — the plan fails if you set it smaller, because the
download would run out of disk at boot.

## AWS instances that can run Strata

Published engine packages contain code for **sm_75, sm_80, sm_86, sm_89 and sm_120**
only. A card outside that set exits before loading a model.

| Family | GPU | Compute cap. | VRAM/GPU | RAM at 8xlarge | Local NVMe | OD $/hr | Spot $/hr |
|--------|-----|:------------:|---------:|---------------:|-----------:|--------:|----------:|
| g5 | A10G | 8.6 | 24 GiB | 128 GiB | 900 GiB | 2.448 | 1.090 |
| g6 | L4 | 8.9 | 24 GiB | 128 GiB | 450 GiB | 2.014 | 0.945 |
| g6e | L40S | 8.9 | 48 GiB | 256 GiB | 450 GiB | 4.529 | 2.317 |
| **g7** | **RTX PRO 4500 Blackwell** | **12.0** | 32 GiB | 128 GiB | 930 GiB | 4.086 | **0.768** |
| **g7e** | **RTX PRO 6000 Blackwell** | **12.0** | **96 GiB** | 256 GiB | 1900 GiB | 5.268 | 3.190 |

Multi-GPU sizes exist (`g6e.24xlarge` = 4× L40S, `g7e.24xlarge` = 4 and
`g7e.48xlarge` = 8 RTX PRO 6000). Strata does use several cards
(`--gpus`, `--gpu-roles`), but this module does not pass them yet.

**Cannot run Strata** (no engine package for their compute capability): P5 / P5e /
P5en (Hopper, sm_90), P6-B200 (sm_100), P6-B300, P6e-GB200, G5g (arm64 — the images
are x86-64 and need AVX2), Trn2 (not CUDA).

## NVFP4 specifically

* Only **sm_120** has FP4 tensor cores. On any other NVIDIA card NVFP4 still runs, at
  **8-bit precision**.
* **g7e.8xlarge** is the natural AWS fit: 96 GiB VRAM against 68 GB of experts, 256 GiB
  RAM above the 80 GB figure, and 1.9 TB of NVMe.
* **g7.8xlarge** is the cheap FP4 experiment (spot $0.768) but its 32 GiB VRAM and
  128 GiB RAM keep only part of the experts resident.
* Below the RAM figure Strata offers a RAM-budget mode
  (`--resident-budget-gib` ≈ RAM − 24 GB) rather than refusing; the rest is read from
  SSD, so a fast local disk matters more than raw GPU throughput — NVFP4 decode runs
  at ~89 % of the card's memory bandwidth.
* Strata holds the FP4-activation prefill mode (`STRATA_PREFILL_NVFP4=w4a4x2`) back
  "until a 96 GB or larger RTX 50 PC" measures it — which is exactly `g7e.8xlarge`.

## Choosing between quality and cost

| Want | Model | Instance |
|------|-------|----------|
| Cheapest serving | Q2_0 or IQ2_XS | g5.8xlarge or g6.8xlarge spot |
| Best quality-per-hour on Ada | IQ3_XXS | g6e.8xlarge |
| Best quality overall | Q8_0 / UD-Q6_K_XL | g6e.24xlarge or g7e.24xlarge |
| NVFP4 at full FP4 speed | NVFP4 | **g7e.8xlarge** |
| NVFP4 cheap to try | NVFP4 | g7.8xlarge spot (8-bit path) |
| Smallest memory footprint | Gyro-S | g5.xlarge / g6.xlarge |

