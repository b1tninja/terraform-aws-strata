# ─── Boot-hook contract assertions ───────────────────────────────────────────────
# A hook is opaque text: nothing in Terraform can type-check it against the boot script
# it gets spliced into, so a broken hook would otherwise surface only at boot on a
# rented GPU. Planning this config asserts the contract instead. No providers, no AWS
# data sources, so it runs without credentials:
#
#   terraform -chdir=tests/boot_hooks init -backend=false
#   terraform -chdir=tests/boot_hooks plan

module "steer" {
  source = "../../modules/strata-control-vector"

  model        = "NVFP4"
  model_family = "nvfp4"
}

module "steer_by_default" {
  source = "../../modules/strata-control-vector"

  model        = "NVFP4"
  model_family = "nvfp4"

  default_on        = true
  separate_endpoint = true
}

locals {
  hook       = module.steer.boot_hook
  hook_named = module.steer_by_default.boot_hook
}

resource "terraform_data" "contract" {
  input = {
    bytes = length(local.hook)
  }

  lifecycle {
    # It rendered something substantial rather than an empty string.
    precondition {
      condition     = length(local.hook) > 500
      error_message = "The control-vector hook rendered empty or trivial text, so the template or its inputs are broken."
    }

    # The base boot script owns these names; a hook that redefines them corrupts every
    # hook after it, which is the failure mode a contract most needs to prevent.
    precondition {
      condition     = !can(regex("(?m)^DATA_MOUNT=", local.hook))
      error_message = "The hook assigns DATA_MOUNT, which belongs to the base boot script. Use a hook-prefixed name."
    }

    precondition {
      condition     = !can(regex("(?m)^PORT=", local.hook))
      error_message = "The hook assigns PORT, which belongs to the base boot script. Use a hook-prefixed name."
    }

    precondition {
      condition     = !can(regex("wait_loaded\\(\\)\\s*\\{", local.hook))
      error_message = "The hook redefines wait_loaded(), which the base boot script provides. Call it, do not replace it."
    }

    # It must keep using the two mechanisms the design depends on: verify the bytes, and
    # record them as user_args, the field the engine merges over generated arguments.
    precondition {
      condition     = can(regex("sha256sum --check", local.hook))
      error_message = "The hook no longer verifies the pinned digest. An unverified steering vector must never be loaded."
    }

    precondition {
      condition     = can(regex("user_args", local.hook))
      error_message = "The hook no longer writes user_args, which is the only run-config field that survives the engine rewriting the file."
    }

    # The vector is loaded when the engine starts, so the hook has to restart it once.
    precondition {
      condition     = can(regex("docker restart strata", local.hook))
      error_message = "The hook no longer restarts the container, so the engine would start without the vector and ignore the per-request key."
    }

    # The per-request switch is what keeps one endpoint able to serve both behaviours.
    precondition {
      condition = (
        can(regex("sampling", local.hook)) &&
        can(regex("experimental_speed_projection", local.hook))
      )
      error_message = "The hook no longer sets sampling.experimental_speed_projection, so the deployment would default to steered instead of stock."
    }

    # The base script numbers its own steps [n/6]; a hook inventing step labels would
    # make the boot log lie about the sequence.
    precondition {
      condition     = !can(regex("\\[[0-9]/[0-9]\\]", local.hook))
      error_message = "The hook prints a numbered boot step, but step numbering belongs to the base boot script."
    }
  }
}

resource "terraform_data" "modes" {
  input = {
    default_off = local.hook
    default_on  = local.hook_named
  }

  lifecycle {
    # Default-off writes false; default-on writes true. Both must be explicit, because an
    # absent key means on in this engine.
    precondition {
      condition = (
        can(regex("--argjson on false", local.hook)) &&
        can(regex("--argjson on true", local.hook_named))
      )
      error_message = "default_on does not reach the rendered hook as the sampling default; an absent key would silently mean on."
    }

    # Only separate_endpoint renames the served model.
    precondition {
      condition     = !can(regex("model_name", local.hook)) && can(regex("model_name", local.hook_named))
      error_message = "The model_name patch must appear only when separate_endpoint = true."
    }
  }
}

resource "terraform_data" "audit" {
  input = module.steer.control_vector

  lifecycle {
    precondition {
      condition     = module.steer.control_vector.licence == "qwen"
      error_message = "The gate let through a pack that is not Qwen-licensed, which is the licence rule this hook exists to enforce."
    }

    precondition {
      condition     = module.steer.control_vector.applicability == "measured"
      error_message = "NVFP4 is one of the packs the vector was measured on, so applicability must say so."
    }

    # 9 tokens, not 8: the recipe is --control-vector-scaled <path> (2),
    # --control-vector-layer-range 8 33 (3), --cvec-mode project (2), --cvec-dir per-layer (2).
    # This counted wrong and the dir could not even plan until its local module was installed,
    # which is how a failing assertion sat unnoticed. Shape is checked as well as length, so a
    # future edit fails with a message that says which piece moved.
    precondition {
      condition = (
        length(module.steer.control_vector.engine_args) == 9 &&
        module.steer.control_vector.engine_args[0] == "--control-vector-scaled" &&
        module.steer.control_vector.engine_args[2] == "--control-vector-layer-range" &&
        module.steer.control_vector.engine_args[3] == "8" &&
        module.steer.control_vector.engine_args[4] == "33" &&
        contains(module.steer.control_vector.engine_args, "project") &&
        contains(module.steer.control_vector.engine_args, "per-layer") &&
        !contains(module.steer.control_vector.engine_args, "remove") &&
        !contains(module.steer.control_vector.engine_args, "pos-neg")
      )
      error_message = "The engine recipe must be the measured one: scaled path, layer range 8 33, cvec-mode project, cvec-dir per-layer. remove/pos-neg is upstream's stale prose, not the shipped arguments."
    }

    precondition {
      condition     = alltrue([for a in module.steer.control_vector.engine_args : !can(regex("(?i)sha1", a))])
      error_message = "Nothing in the recipe should mention SHA-1; upstream's prose is stale and the digests are SHA-256."
    }
  }
}

output "hook_bytes" {
  description = "Size of the rendered hook, so a plan shows that real text was produced"
  value       = length(local.hook)
}
