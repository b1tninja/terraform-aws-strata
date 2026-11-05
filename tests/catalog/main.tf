# ─── Catalog assertions ──────────────────────────────────────────────────────────
# terraform validate never evaluates expressions, so the catalog is proved by
# planning this config: every precondition below is checked during plan. It has no
# providers and no AWS data sources, so it runs without credentials:
#
#   terraform -chdir=tests/catalog init -backend=false
#   terraform -chdir=tests/catalog plan

module "clean" {
  source = "../../modules/strata-catalog"

  model         = "IQ3_XXS"
  model_family  = "qwen"
  instance_type = "g7e.8xlarge"
}

module "nvfp4_on_ada" {
  source = "../../modules/strata-catalog"

  model         = "NVFP4"
  model_family  = "nvfp4"
  instance_type = "g6e.8xlarge"
}

module "nvfp4_on_blackwell" {
  source = "../../modules/strata-catalog"

  model         = "NVFP4"
  model_family  = "nvfp4"
  instance_type = "g7e.8xlarge"
}

module "nvfp4_qad" {
  source = "../../modules/strata-catalog"

  model         = "NVFP4-QAD"
  model_family  = "nvfp4"
  instance_type = "g7e.8xlarge"
}

module "on_hopper" {
  source = "../../modules/strata-catalog"

  model         = "IQ3_XXS"
  model_family  = "qwen"
  instance_type = "p6-b200.48xlarge"
}

module "unknown_model" {
  source = "../../modules/strata-catalog"

  model         = "IQ3_XXX"
  model_family  = "qwen"
  instance_type = "g6e.8xlarge"
}

module "wrong_family" {
  source = "../../modules/strata-catalog"

  model         = "Q8_0"
  model_family  = "qwen"
  instance_type = "g6e.8xlarge"
}

module "tight_ram" {
  source = "../../modules/strata-catalog"

  model         = "Q8_0"
  model_family  = "unsloth"
  instance_type = "g5.8xlarge"
}

# The same pack on a box with enough RAM does not spill, so it must not get the scratch
# advice. NVFP4 wants 80 GiB; g7.4xlarge has 64 and g7e.8xlarge has 256.
module "budget_spill" {
  source = "../../modules/strata-catalog"

  model         = "NVFP4"
  model_family  = "nvfp4"
  instance_type = "g7.4xlarge"
}

resource "terraform_data" "assertions" {
  input = "catalog invariants"

  lifecycle {
    # ─── Catalog integrity ───────────────────────────────────────────────────────
    precondition {
      condition     = alltrue([for m in module.clean.models : m.download_gb > 0])
      error_message = "Every catalog model needs a positive download_gb to size a volume."
    }
    precondition {
      condition     = alltrue([for m in module.clean.models : length(m.families) > 0])
      error_message = "Every catalog model must name at least one family that offers it."
    }
    precondition {
      condition = alltrue([
        for m in module.clean.models :
        alltrue([for f in m.families : contains(module.clean.family_names, f)])
      ])
      error_message = "Every model's family must appear in family_names."
    }
    precondition {
      condition = alltrue([
        for name, f in module.clean.instances :
        !f.supported || contains(module.clean.supported_compute_capabilities, f.compute_capability)
      ])
      error_message = "A supported family must name a compute capability the engine packages cover."
    }
    precondition {
      condition     = length(module.clean.fp4_type_names) > 0 && alltrue([for t in module.clean.fp4_type_names : startswith(t, "g7")])
      error_message = "FP4 must be limited to the sm_120 families (g7, g7e)."
    }

    # ─── Resolution ──────────────────────────────────────────────────────────────
    precondition {
      condition     = length(module.clean.notes) == 0 && !module.clean.hard_error
      error_message = "IQ3_XXS on qwen/g7e.8xlarge should resolve cleanly, with no notes."
    }
    precondition {
      condition     = module.clean.min_volume_gib == 126 && module.clean.recommended_volume_gib == 130
      error_message = "IQ3_XXS (75.8 GB) plus 50 GB headroom should be 126 GiB, rounded to 130."
    }
    precondition {
      condition     = length(module.nvfp4_on_ada.notes) == 1 && can(regex("8-bit precision", module.nvfp4_on_ada.notes[0]))
      error_message = "NVFP4 on an Ada card should note the 8-bit fallback."
    }
    precondition {
      condition     = length(module.nvfp4_on_blackwell.notes) == 1 && can(regex("FP4 tensor cores", module.nvfp4_on_blackwell.notes[0]))
      error_message = "NVFP4 on g7e should note that it gets FP4 tensor cores."
    }
    precondition {
      condition     = module.nvfp4_qad.min_volume_gib == 263 && module.nvfp4_qad.recommended_volume_gib == 270
      error_message = "NVFP4-QAD needs its 110 GB conversion space counted (102.2 + 110 + 50 = 263, rounded 270)."
    }
    precondition {
      condition     = module.on_hopper.hard_error && can(regex("cannot run Strata", module.on_hopper.notes[0]))
      error_message = "A datacenter Blackwell instance must be flagged as unable to run Strata."
    }
    precondition {
      condition     = !module.unknown_model.known_model && !module.unknown_model.hard_error
      error_message = "An unknown model id should be reported, not turned into a hard error."
    }
    precondition {
      condition     = !module.wrong_family.family_offers_model && can(regex("does not offer model", module.wrong_family.notes[0]))
      error_message = "Q8_0 is Unsloth-only, so family qwen must be rejected."
    }
    precondition {
      condition     = can(regex("RAM-budget mode", module.tight_ram.notes[0]))
      error_message = "Q8_0 on 128 GiB of RAM (below its 136 GiB need) should explain RAM-budget mode."
    }

    # ─── Scratch advice (modules/strata-instance-store) ────────────────────────────
    # The advice exists to connect a known spill to a disk that is already paid for, so it
    # must appear when the pack spills and stay quiet when it does not. Both directions are
    # asserted: an always-on note would be noise, a never-firing one would be dead code.
    precondition {
      condition     = anytrue([for n in module.budget_spill.notes : can(regex("instance-store NVMe", n))])
      error_message = "NVFP4 on g7.4xlarge has 64 GiB of RAM against an 80 GiB need, so it spills and should be pointed at the local NVMe."
    }
    precondition {
      condition     = !anytrue([for n in module.nvfp4_on_blackwell.notes : can(regex("instance-store NVMe", n))])
      error_message = "NVFP4 on g7e.8xlarge has 256 GiB of RAM, above its need: nothing spills, so the scratch advice must not fire."
    }
  }
}

output "volume_sizes_gib" {
  description = "What data_volume_size each model derives to, for eyeballing in CI"
  value       = module.clean.volume_sizes_gib
}
