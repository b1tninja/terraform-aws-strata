# ─── Strata model and AWS instance catalog ─────────────────────────────────────
# Pure data and arithmetic: no providers and no AWS data sources, so it can be planned
# (and its invariants asserted) without credentials. See tests/catalog.
#
# Model numbers are transcribed from Strata's own catalog, the source of truth for
# sizes (niko1221/strata setup.py, dict MODELS at line 410, read 2026-11-04). Do not
# hand-edit a number here to match a benchmark: re-read setup.py instead. A
# hand-copied table is how docs/MODELS.md drifted from it (Q2_0 was listed at 58 GB
# of disk and 37.6 GB of RAM against Strata's 66.4 and 48).
#
# Other sources recorded per field below:
#   docs/MODELS.md      234-245  NVFP4: ~80 GB RAM; "RTX 50 has FP4 tensor cores,
#                                other NVIDIA cards run NVFP4 at 8-bit precision"
#   docs/NVFP4.md       26-27    RAM-budget mode: --resident-budget-gib = RAM - 24 GB
#   docs/DEEPSEEK41.md  29-38    ISTA sets 121/138/155 GB + shared 111 GB Engram
#   Dockerfile          31       the cuda13 image ships sm_75/80/86/89/120
#   CMakeLists.txt      2189     the FP4 MMA unit is sm_120 only
#   docker/entrypoint.sh 139-150 an unsupported card exits 3 before any download
#
# ram_gb = system RAM Strata wants to keep every expert resident. For the "budget"
# packs it is the all-in-RAM need, and below it setup offers the RAM-budget mode.
# arena_gb is recorded exactly as Strata publishes it; nothing here interprets it.

locals {
  # Compute capabilities the published engine packages contain code for. Anything
  # else (sm_90 Hopper, sm_100 datacenter Blackwell) cannot run Strata at all.
  supported_compute_capabilities = [7.5, 8.0, 8.6, 8.9, 12.0]

  # The only capability with FP4 tensor cores (CMakeLists.txt:2189).
  fp4_compute_capability = 12.0

  # Disk headroom on top of the download: pack, tuning data, MTP layer, logs.
  default_volume_headroom_gib = 50

  models = {
    Q2_0 = {
      download_gb = 66.4, ram_gb = 48, arena_gb = 34.0
      families    = ["qwen"], vision = false, budget = false, shards = 2
      min_engine  = "0.1.26", license = "qwen", fp4 = false
      about       = "2-bit, the fastest"
    }
    IQ2_XS = {
      download_gb = 68.0, ram_gb = 48, arena_gb = 35.5
      families    = ["qwen", "swift"], vision = false, budget = false, shards = 2
      min_engine  = "0.1.26", license = "qwen", fp4 = false
      about       = "2-bit i-quant, a little better quality, close in speed"
    }
    IQ3_XXS = {
      download_gb = 75.8, ram_gb = 60, arena_gb = 42.9
      families    = ["qwen", "swift"], vision = true, budget = false, shards = 2
      min_engine  = "0.1.26", license = "qwen", fp4 = false
      about       = "3-bit i-quant, better quality, slower (more CPU work per token)"
    }
    IQ3_S = {
      download_gb = 83.6, ram_gb = 62, arena_gb = 50.3
      families    = ["qwen", "swift"], vision = true, budget = false, shards = 2
      min_engine  = "0.1.26", license = "qwen", fp4 = false
      about       = "3.5-bit i-quant, matches the full model, the slowest"
    }
    IQ1_M = {
      download_gb = 58.4, ram_gb = 32, arena_gb = 23.4
      families    = ["coder"], vision = true, budget = false, shards = 2
      min_engine  = "0.1.26", license = "qwen", fp4 = false
      about       = "the Coder's only size: half the experts, stored like IQ3_S"
    }
    UD-IQ4_XS = {
      download_gb = 93.7, ram_gb = 48, arena_gb = 59.5
      families    = ["unsloth"], vision = true, budget = true, shards = 3
      min_engine  = "0.1.38", license = "qwen", fp4 = false
      about       = "~4-bit i-quant (Unsloth Dynamic), between IQ3_S and UD-Q4_K_XL"
    }
    UD-Q4_K_XL = {
      download_gb = 111.3, ram_gb = 48, arena_gb = 77.0
      families    = ["unsloth"], vision = true, budget = true, shards = 2
      min_engine  = "0.1.31", license = "qwen", fp4 = false
      about       = "4-bit (Unsloth Dynamic): K-quant experts"
    }
    UD-Q5_K_XL = {
      download_gb = 158.3, ram_gb = 108, arena_gb = 98.4
      families    = ["unsloth"], vision = true, budget = true, shards = 6
      min_engine  = "0.1.44", license = "qwen", fp4 = false
      about       = "5-bit (Unsloth Dynamic): Q5_K experts with Q8_0 downs"
    }
    UD-Q6_K_XL = {
      download_gb = 169.2, ram_gb = 118, arena_gb = 109.2
      families    = ["unsloth"], vision = true, budget = true, shards = 6
      min_engine  = "0.1.44", license = "qwen", fp4 = false
      about       = "6-bit (Unsloth Dynamic): Q6_K experts with Q8_0 downs"
    }
    Q8_0 = {
      download_gb = 188.2, ram_gb = 136, arena_gb = 128.3
      families    = ["unsloth"], vision = true, budget = true, shards = 6
      min_engine  = "0.1.38", license = "qwen", fp4 = false
      about       = "8-bit, the reference quality (every expert Q8_0)"
    }
    # Gyro states its need as VRAM + RAM together ("mem_total" in setup.py), so its
    # ram_gb is that combined figure rather than system RAM alone.
    Gyro-S = {
      download_gb = 58.5, ram_gb = 28, arena_gb = 25.8
      families    = ["gyro"], vision = true, budget = false, shards = 1
      min_engine  = "0.1.45.1", license = "qwen", fp4 = false
      about       = "the smallest option; 27.6 GB of VRAM + RAM together"
    }
    Gyro-M = {
      download_gb = 92.0, ram_gb = 35, arena_gb = 32.1
      families    = ["gyro"], vision = true, budget = false, shards = 1
      min_engine  = "0.1.45.1", license = "qwen", fp4 = false
      about       = "about IQ3_XXS quality with about 20% less GPU memory (35 GB of VRAM + RAM)"
    }
    # The three NVFP4 packs share family "nvfp4" and need NVIDIA kernels. They differ
    # in LICENCE, and only the Qwen-licensed one may carry a control vector that
    # removes refusals (setup.py:477-497; strata-launcher Get-UncensorRefusal).
    NVFP4 = {
      download_gb = 128.0, ram_gb = 80, arena_gb = 68.0
      families    = ["nvfp4"], vision = true, budget = true, shards = null
      min_engine  = "0.1.44", license = "qwen", fp4 = true
      about       = "best quality of the NVFP4 versions (GPTQ, sergqwer's strata-nvfp4 pack)"
      hf_repo     = "Maximilian228/Qwen3.8-Flash-Next-NVFP4-GPTQ-Strata"
    }
    NVFP4-NVIDIA = {
      download_gb = 128.0, ram_gb = 80, arena_gb = 68.0
      families    = ["nvfp4"], vision = true, budget = true, shards = null
      min_engine  = "0.1.44", license = "nvidia", fp4 = true
      about       = "NVIDIA's own NVFP4 checkpoint (plain rounding), converted by sergqwer"
      hf_repo     = "Maximilian228/Qwen3.8-Flash-Next-NVIDIA-NVFP4-Strata"
    }
    NVFP4-QAD = {
      download_gb = 102.2, ram_gb = 80, arena_gb = 68.0
      families    = ["nvfp4"], vision = true, budget = true, shards = null
      min_engine  = "0.1.45", license = "nvidia", fp4 = true, prepare_gb = 110.0
      about       = "NVIDIA's FP4 trained for FP4 (FP4-Local); the instance converts it once"
      hf_repo     = "nvidia/Qwen3.8-Flash-Next-FP4-Local"
    }
    # DeepSeek V4.1-Flash is a separate architecture with its own engine package.
    # download_gb is the whole footprint: model shards + the shared 111 GB Engram
    # n-gram table + the 8 GB DSpark drafter, as docs/DEEPSEEK41.md quotes it.
    "IST-DAS-1.75bpw" = {
      download_gb = 239.0, ram_gb = 40, arena_gb = null
      families    = ["deepseek41"], vision = false, budget = true, shards = 4
      min_engine  = null, license = "deepseek", fp4 = false
      about       = "the 1.75 bpw ISTA set (121 GB of shards), the smallest"
    }
    "IST-DAS-2.00bpw" = {
      download_gb = 257.0, ram_gb = 40, arena_gb = null
      families    = ["deepseek41"], vision = false, budget = true, shards = 4
      min_engine  = null, license = "deepseek", fp4 = false
      about       = "the 2.00 bpw ISTA set (138 GB of shards), the middle"
    }
    "IST-DAS-2.25bpw" = {
      download_gb = 274.0, ram_gb = 40, arena_gb = null
      families    = ["deepseek41"], vision = false, budget = true, shards = 4
      min_engine  = null, license = "deepseek", fp4 = false
      about       = "the 2.25 bpw ISTA set (155 GB of shards), the largest"
    }
    UD-Q8_K_XL = {
      download_gb = 508.0, ram_gb = null, arena_gb = null
      families    = ["deepseek41"], vision = false, budget = true, shards = 9
      min_engine  = null, license = "deepseek", fp4 = false
      about       = "Unsloth's 508 GB set, for hundreds of GB of RAM or several cards"
    }
  }

  model_ids = keys(local.models)

  # Every family name Strata accepts (docs/DOCKER.md:116 plus deepseek41/nvfp4).
  family_names = distinct(flatten([for m in local.models : m.families]))
}
