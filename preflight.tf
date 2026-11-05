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
