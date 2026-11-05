# ─── AWS instance catalog ──────────────────────────────────────────────────────
# Specs from instances.vantage.sh and docs.aws.amazon.com/ec2/latest/instancetypes/
# ac.md, read 2026-11-04 (us-east-1, Linux). ram_gib per size comes from each
# family's published size table; gpus_verified records only counts actually checked.
#
# supported = false is the expensive mistake this file exists to prevent. P5/P6 are
# Hopper (sm_90) and datacenter Blackwell (sm_100), and no published Strata engine
# package contains code for them (Dockerfile:31 ships sm_75/80/86/89/120; the DeepSeek
# release shape is sm_86/89/120, CMakeLists.txt:224). The container exits 3 with
# "the engine in this image does not match this computer's graphics card"
# (docker/entrypoint.sh:139-150) - after you have paid for the instance and booted it.

locals {
  instances = {
    g5 = {
      gpu       = "NVIDIA A10G", compute_capability = 8.6, vram_per_gpu_gib = 24
      supported = true, introduced = "2021-11-12", note = "Ampere; the cheap option"
      sizes = {
        "g5.xlarge"   = 16, "g5.2xlarge" = 32, "g5.4xlarge" = 64, "g5.8xlarge" = 128
        "g5.12xlarge" = 192, "g5.16xlarge" = 256, "g5.24xlarge" = 384, "g5.48xlarge" = 768
      }
      reference = { instance_type = "g5.8xlarge", nvme_gib = 900, on_demand_usd_hour = 2.448, spot_usd_hour = 1.090 }
    }
    g6 = {
      gpu       = "NVIDIA L4", compute_capability = 8.9, vram_per_gpu_gib = 24
      supported = true, introduced = "2024-04-04", note = "Ada, 24 GB"
      sizes = {
        "g6.xlarge"   = 16, "g6.2xlarge" = 32, "g6.4xlarge" = 64, "g6.8xlarge" = 128
        "g6.12xlarge" = 192, "g6.16xlarge" = 256, "g6.24xlarge" = 384, "g6.48xlarge" = 768
      }
      reference = { instance_type = "g6.8xlarge", nvme_gib = 450, on_demand_usd_hour = 2.014, spot_usd_hour = 0.945 }
    }
    g6e = {
      gpu       = "NVIDIA L40S", compute_capability = 8.9, vram_per_gpu_gib = 48
      supported = true, introduced = "2024-08-15"
      note      = "Ada, 48 GB; the long-standing recommendation for this module"
      sizes = {
        "g6e.xlarge"   = 32, "g6e.2xlarge" = 64, "g6e.4xlarge" = 128, "g6e.8xlarge" = 256
        "g6e.12xlarge" = 384, "g6e.16xlarge" = 512, "g6e.24xlarge" = 768, "g6e.48xlarge" = 1536
      }
      reference     = { instance_type = "g6e.8xlarge", nvme_gib = 450, on_demand_usd_hour = 4.529, spot_usd_hour = 2.317 }
      gpus_verified = { "g6e.8xlarge" = 1, "g6e.24xlarge" = 4 }
    }
    g7 = {
      gpu       = "NVIDIA RTX PRO 4500 Blackwell", compute_capability = 12.0, vram_per_gpu_gib = 32
      supported = true, introduced = "2026-06-18"
      note      = "sm_120, so it has FP4 tensor cores; the cheapest FP4-capable box. 32 GB VRAM and 128 GB RAM pin only part of NVFP4's 68 GB of experts"
      sizes = {
        "g7.2xlarge"  = 32, "g7.4xlarge" = 64, "g7.8xlarge" = 128
        "g7.12xlarge" = 192, "g7.24xlarge" = 384, "g7.48xlarge" = 768
      }
      reference = { instance_type = "g7.8xlarge", nvme_gib = 930, on_demand_usd_hour = 4.086, spot_usd_hour = 0.768 }
    }
    g7e = {
      gpu       = "NVIDIA RTX PRO 6000 Blackwell", compute_capability = 12.0, vram_per_gpu_gib = 96
      supported = true, introduced = "2026-01-20"
      note      = "sm_120 with 96 GB VRAM: the AWS box NVFP4 was written for. docs/NVFP4.md holds its FP4-activation mode back until a 96 GB-or-larger RTX 50 PC measures it"
      sizes = {
        "g7e.2xlarge"  = 64, "g7e.4xlarge" = 128, "g7e.8xlarge" = 256
        "g7e.12xlarge" = 512, "g7e.24xlarge" = 1024, "g7e.48xlarge" = 2048
      }
      reference     = { instance_type = "g7e.8xlarge", nvme_gib = 1900, on_demand_usd_hour = 5.268, spot_usd_hour = 3.190 }
      gpus_verified = { "g7e.8xlarge" = 1, "g7e.24xlarge" = 4, "g7e.48xlarge" = 8 }
    }

    # Listed so a wrong choice gets a specific message instead of "unknown type".
    p5 = {
      gpu        = "NVIDIA H100", compute_capability = 9.0, vram_per_gpu_gib = 80, supported = false
      introduced = null, note = "Hopper sm_90: no published Strata engine package covers it"
      sizes      = { "p5.4xlarge" = 256, "p5.48xlarge" = 2048 }
      reference  = { instance_type = "p5.48xlarge", nvme_gib = null, on_demand_usd_hour = null, spot_usd_hour = null }
    }
    p5e = {
      gpu        = "NVIDIA H100 (141 GB)", compute_capability = 9.0, vram_per_gpu_gib = 141, supported = false
      introduced = null, note = "Hopper sm_90: no published Strata engine package covers it"
      sizes      = { "p5e.48xlarge" = 2048 }
      reference  = { instance_type = "p5e.48xlarge", nvme_gib = null, on_demand_usd_hour = null, spot_usd_hour = null }
    }
    p5en = {
      gpu        = "NVIDIA H200", compute_capability = 9.0, vram_per_gpu_gib = 141, supported = false
      introduced = null, note = "Hopper sm_90: no published Strata engine package covers it"
      sizes      = { "p5en.48xlarge" = 2048 }
      reference  = { instance_type = "p5en.48xlarge", nvme_gib = null, on_demand_usd_hour = null, spot_usd_hour = null }
    }
    p6-b200 = {
      gpu        = "NVIDIA B200", compute_capability = 10.0, vram_per_gpu_gib = 180, supported = false
      introduced = "2025-05-15"
      note       = "datacenter Blackwell sm_100: it has FP4 hardware but is not sm_120, so no engine package covers it"
      sizes      = { "p6-b200.48xlarge" = 2048 }
      reference  = { instance_type = "p6-b200.48xlarge", nvme_gib = 3800, on_demand_usd_hour = 113.933, spot_usd_hour = 83.623 }
    }
    p6-b300 = {
      gpu        = "NVIDIA B300", compute_capability = null, vram_per_gpu_gib = null, supported = false
      introduced = null, note = "datacenter Blackwell Ultra: no published Strata engine package covers it"
      sizes      = { "p6-b300.48xlarge" = null }
      reference  = { instance_type = "p6-b300.48xlarge", nvme_gib = null, on_demand_usd_hour = null, spot_usd_hour = null }
    }
    p6e-gb200 = {
      gpu        = "NVIDIA GB200 NVL", compute_capability = null, vram_per_gpu_gib = null, supported = false
      introduced = null, note = "datacenter Blackwell superchip: no published Strata engine package covers it"
      sizes      = { "p6e-gb200.36xlarge" = null }
      reference  = { instance_type = "p6e-gb200.36xlarge", nvme_gib = null, on_demand_usd_hour = null, spot_usd_hour = null }
    }
    g5g = {
      gpu        = "Graviton + GPU", compute_capability = null, vram_per_gpu_gib = 16, supported = false
      introduced = null, note = "arm64: the Strata images are linux-x86_64 and the engine needs AVX2"
      sizes      = { "g5g.xlarge" = 8, "g5g.8xlarge" = 32, "g5g.16xlarge" = 64 }
      reference  = { instance_type = "g5g.8xlarge", nvme_gib = null, on_demand_usd_hour = null, spot_usd_hour = null }
    }
    trn2 = {
      gpu        = "AWS Trainium2", compute_capability = null, vram_per_gpu_gib = null, supported = false
      introduced = null, note = "not an NVIDIA CUDA device"
      sizes      = { "trn2.3xlarge" = 32, "trn2.48xlarge" = 2048 }
      reference  = { instance_type = "trn2.3xlarge", nvme_gib = null, on_demand_usd_hour = null, spot_usd_hour = null }
    }
  }

  # Flat instance-type lookup: each family's size table expanded to one entry per type.
  instance_types = merge([
    for fam, f in local.instances : {
      for it, ram in f.sizes :
      it => merge(f, {
        family  = fam
        ram_gib = ram
        fp4     = try(f.compute_capability == local.fp4_compute_capability, false)
      })
    }
  ]...)

  instance_type_names  = keys(local.instance_types)
  supported_type_names = [for it, v in local.instance_types : it if v.supported]
  fp4_type_names       = [for it, v in local.instance_types : it if v.supported && v.fp4]
}
