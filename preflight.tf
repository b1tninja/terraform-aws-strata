# ─── Preflight ───────────────────────────────────────────────────────────────────
# Everything the catalog knows but AWS will not tell you until an instance is already
# booted and billed. Preconditions run during plan, so a wrong choice fails here.

locals {
  # Hoisted: HCL cannot parse a for-expression containing commas inside "${ }".
  supported_families = join(", ", distinct([for t in module.catalog.supported_type_names : split(".", t)[0]]))
}

resource "terraform_data" "preflight" {
  input = {
    model         = var.model
    model_family  = var.model_family
    instance_type = var.instance_type
    volume_gib    = local.data_volume_size
  }

  lifecycle {
    precondition {
      condition     = module.catalog.known_model || !var.strict_catalog
      error_message = "model \"${var.model}\" is not in the catalog. Known sizes: ${join(", ", module.catalog.model_ids)}. Set strict_catalog = false to deploy a size the catalog has not been updated for yet."
    }

    precondition {
      condition     = module.catalog.known_family || !var.strict_catalog
      error_message = "model_family \"${var.model_family}\" is not a Strata family. Known families: ${join(", ", module.catalog.family_names)}."
    }

    precondition {
      condition     = !module.catalog.known_model || !module.catalog.known_family || module.catalog.family_offers_model
      error_message = "model_family \"${var.model_family}\" does not offer model \"${var.model}\". Strata's catalog pairs each size with the families that publish it."
    }

    # The expensive one: P5/P6 boot, pull a 128 GB volume and then exit 3.
    precondition {
      condition     = module.catalog.instance_supported != false
      error_message = "instance_type \"${var.instance_type}\" cannot run Strata: no published engine package covers its compute capability, so the container exits before loading a model. Supported families: ${local.supported_families}."
    }

    precondition {
      condition     = try(module.catalog.min_volume_gib, null) == null || local.data_volume_size >= module.catalog.min_volume_gib
      error_message = "data_volume_size ${local.data_volume_size} GiB cannot hold model \"${var.model}\": it needs at least ${module.catalog.min_volume_gib} GiB. Leave data_volume_size unset to derive it."
    }
  }
}

# The container knobs are passed straight through to the image, so without these the
# first feedback would be a boot failure on a rented GPU after 128 GB has been restored.
resource "terraform_data" "container_knobs" {
  input = {
    tune_mode = var.tune_mode
    parallel  = var.parallel
    gpus      = var.gpus
    gpu_roles = var.gpu_roles
  }

  lifecycle {
    precondition {
      condition     = contains(["quick", "thorough", "skip"], var.tune_mode)
      error_message = "tune_mode must be quick, thorough or skip. The entrypoint lower-cases it and ignores anything else (docker/entrypoint.sh:229-230), so a typo silently means no tuning."
    }

    precondition {
      condition     = var.parallel == null || (var.parallel >= 1 && var.parallel <= 8)
      error_message = "parallel is 1 to 8 requests answered at the same time, or unset to let the container fit it to the card."
    }

    precondition {
      condition     = var.gpus == "" || var.gpu_roles == ""
      error_message = "gpus and gpu_roles are mutually exclusive: the container dies with \"Set GPU_ROLES or GPU / GPUS, not both\" (docker/entrypoint.sh:222)."
    }

    precondition {
      condition     = var.gpus == "" || can(regex("^[0-9]+(,[0-9]+)*$", var.gpus))
      error_message = "gpus must be comma-separated card numbers as the monitor lists them, e.g. \"0\" or \"0,1\"."
    }

    precondition {
      condition     = var.gpu_roles == "" || can(regex("^[0-9]+=(main|helper|off)(,[0-9]+=(main|helper|off))*$", var.gpu_roles))
      error_message = "gpu_roles must be comma-separated card=role pairs with the role one of main, helper or off, e.g. \"1=main,0=helper\"."
    }
  }
}


# Upstream publishes both moving tags (latest-cuda13) and pinned ones (0.2.9-cuda13, and per
# backend: -cuda12, -rocm-gfx*, -sycl). A moving tag means two boots of this exact configuration
# can run different engine builds. That matters more here than in a typical deployment: the
# control-vector layer pins a commit and an explicit set of engine arguments precisely because
# upstream's documentation and its shipped defaults have been observed to disagree, so the engine
# underneath those pins should not be free to move between boots.
check "image_tag_pinned" {
  assert {
    condition     = !startswith(var.strata_image_tag, "latest")
    error_message = "strata_image_tag is \"${var.strata_image_tag}\", a moving tag: the next boot of this unchanged configuration can pull a different engine build. Pin one instead (ghcr.io/niko1221/strata publishes <version>-cuda12, -cuda13, -rocm-gfx*, -sycl). Note the images can lag the app release, so the newest tag is not always the newest engine."
  }
}

# The verification mode is read by the boot script, so a typo would mean the check silently
# does the wrong thing on every instance built from this configuration.
resource "terraform_data" "verify_weights" {
  input = var.verify_weights

  lifecycle {
    precondition {
      condition     = contains(["off", "sizes", "full"], var.verify_weights)
      error_message = "verify_weights must be \"off\", \"sizes\" or \"full\". Anything else is compared literally by the boot script, so it would fall through to the sizes pass while looking like something else."
    }
  }
}

