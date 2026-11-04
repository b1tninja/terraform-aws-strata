# Model → Instance Mapping

## Quick Reference

| Model | Family | Disk Size | RAM+VRAM Needed | Min Instance | Recommended |
|-------|--------|-----------|-----------------|-------------|-------------|
| Q2_0 | qwen | 58 GB | 37.6 GB | g6e.8xlarge | g6e.8xlarge |
| IQ2_XS | qwen | 60 GB | 39.2 GB | g6e.8xlarge | g6e.8xlarge |
| IQ3_XXS | qwen | 73 GB | 47.0 GB | g6e.8xlarge | g6e.8xlarge |
| IQ3_S | qwen | 85 GB | 54.8 GB | g6e.8xlarge | g6e.12xlarge |
| UD-Q4_K_XL | qwen | 100 GB | 72.0 GB | g6e.12xlarge | g6e.12xlarge |
| UD-Q5_K_XL | qwen | 112 GB | 90.0 GB | g6e.12xlarge | g6e.12xlarge |
| UD-Q6_K_XL | qwen | 130 GB | 108.0 GB | g6e.12xlarge | g6e.24xlarge |
| Q8_0 | qwen | 158 GB | 136.0 GB | g6e.12xlarge | g6e.24xlarge |
| Coder (IQ1_M) | coder | 50 GB | 32.0 GB | g6e.8xlarge | g6e.8xlarge |
| DeepSeek 1.75bpw | deepseek41 | 245 GB | 46 GB + 12GB VRAM | g6e.12xlarge | g6e.24xlarge |
| DeepSeek 2.00bpw | deepseek41 | 265 GB | 50 GB + 12GB VRAM | g6e.12xlarge | g6e.24xlarge |
| DeepSeek 2.25bpw | deepseek41 | 280 GB | 56 GB + 12GB VRAM | g6e.24xlarge | g6e.48xlarge |

## Volume Size Guide

Set `data_volume_size` to at least the disk size + 50GB headroom (for tuning data, MTP layer, logs):

| Model Disk Size | Recommended volume_size |
|----------------|------------------------|
| 50-75 GB | 128 GiB |
| 75-100 GB | 200 GiB |
| 100-150 GB | 250 GiB |
| 150-200 GB | 300 GiB |
| 200-280 GB | 400 GiB |

## GPU Compatibility Notes

All G5 (A10G, compute 8.6) and G6/G6e (L4/L40S, compute 8.9) instances are compatible with Strata's CUDA engine:

- **Strata cuda13 image**: compiled for sm_75, sm_80, sm_86, sm_89, sm_120
- **Strata cuda12 image**: compiled for sm_60, sm_61, sm_70, sm_75, sm_80, sm_86, sm_89
- **L40S (sm_89)** matches RTX 4090 compute capability — same code path as consumer cards
- **A10G (sm_86)** matches RTX 3090 compute capability

### Why VRAM matters for Strata
Each extra GB of VRAM holds ~700 more experts on the GPU. L40S with 48GB holds far more
than L4/A10G with 24GB, meaning fewer experts fall back to CPU computation → faster inference.

For **best performance per dollar**, prefer `g6e` (L40S) over `g6` (L4) or `g5` (A10G).
