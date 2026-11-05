terraform {
  required_version = ">= 1.5.0"
  # No providers, so this plans without credentials like the other tests.
}

module "on" {
  source = "../../modules/strata-instance-store"

  enabled     = true
  scratch_gib = 1900 # g7e.8xlarge reference figure
  weights_gib = 128
}

module "off" {
  source = "../../modules/strata-instance-store"

  enabled     = false
  scratch_gib = 1900
  weights_gib = 128
}

# A pack that will not fit, told to skip rather than fail: the plan must stay green and
# simply not offer a hook.
module "too_small_skip" {
  source = "../../modules/strata-instance-store"

  enabled         = true
  scratch_gib     = 200
  weights_gib     = 250
  min_free_gib    = 40
  on_insufficient = "skip"
}

locals {
  hook  = module.on.pre_start_hook
  lines = split("\n", local.hook)

  # Dots instead of quotes in these patterns: the shell text is quoted, and an escaped quote
  # inside an HCL string is easy to get wrong in a way that only shows up as a parse error.
  # [$] is a literal dollar - a bare $ in Go regexp asserts end of line, and the shell text
  # refers to these as "$SCRATCH_MOUNT".
  verify_lines = [for i, l in local.lines : i if can(regex("verify_copy .[$]SCRATCH_MOUNT", l))]
  bind_lines   = [for i, l in local.lines : i if can(regex("mount --bind .[$]SCRATCH_MOUNT. .[$]DATA_MOUNT", l))]
}

resource "terraform_data" "contract" {
  input = length(local.hook)

  lifecycle {
    precondition {
      condition     = module.on.active && length(module.on.pre_start_hooks) == 1
      error_message = "An enabled layer that fits must produce exactly one pre-start hook."
    }

    precondition {
      condition     = !module.off.active && length(module.off.pre_start_hooks) == 0
      error_message = "enabled = false must produce no hook at all; an empty text spliced into the boot script is not the same as nothing spliced."
    }

    precondition {
      condition     = !module.too_small_skip.fits && length(module.too_small_skip.pre_start_hooks) == 0
      error_message = "on_insufficient = \"skip\" must decline to render when the pack plus headroom exceeds the disk."
    }

    # The contract in the boot script says wait_loaded() does not exist yet at this splice
    # point. A hook that calls it would hang until the health timeout on every boot.
    precondition {
      condition     = !can(regex("wait_loaded", local.hook))
      error_message = "A pre-start hook must not call wait_loaded(); nothing is serving yet."
    }

    # Same contract, other half: these names belong to the base script.
    precondition {
      condition     = !can(regex("DATA_MOUNT=", local.hook)) && !can(regex("DATA_DEVICE=", local.hook))
      error_message = "A hook must not redefine $DATA_MOUNT or $DATA_DEVICE; the base script owns them and other hooks read them."
    }

    # Fail-safe by construction: errexit relaxed inside a subshell, an explicit final true, and
    # a message that says the boot continued. Without this the parent's set -e would let a
    # refused optimisation abort the boot.
    precondition {
      condition = (
        can(regex("set \\+e", local.hook)) &&
        endswith(trim(local.hook, " \r\n"), "true") &&
        can(regex("not used for this boot", local.hook))
      )
      error_message = "The hook must be fail-safe: relax errexit in a subshell, end with true, and say out loud when it declines to run."
    }

    # Instance storage is found by the model string the kernel reports, never by guessing a
    # device name - the mistake that made the mount step unsafe.
    precondition {
      condition     = can(regex("AmazonEC2NVMeInstanceStorage", local.hook)) && !can(regex("/dev/nvme1n1", local.hook))
      error_message = "The scratch disk must be identified by its reported model string, not by a hardcoded device name."
    }

    # The copy is verified before /data is remapped, and a bad copy unmounts rather than
    # half-applies.
    precondition {
      condition = (
        length(local.verify_lines) > 0 &&
        length(local.bind_lines) > 0 &&
        local.verify_lines[0] < local.bind_lines[0] &&
        can(regex("umount .[$]SCRATCH_MOUNT.", local.hook))
      )
      error_message = "The scratch copy must be verified against the manifest before $DATA_MOUNT is bind-mounted over it, and a failure must unmount."
    }

    # Mutable paths leave the copy and stay on the volume the promotion step snapshots.
    precondition {
      condition = (
        can(regex("--exclude=./state", local.hook)) &&
        can(regex("--exclude=./install", local.hook)) &&
        can(regex("for p in install state .strata-manifest; do", local.hook))
      )
      error_message = "install/ and state/ must be excluded from the copy and bind-mounted back from the EBS volume, or tuning state stops surviving to the promote step."
    }

    precondition {
      condition     = can(regex("\\| tar -C", local.hook)) && can(regex("copy_rc=", local.hook))
      error_message = "The copy must be a piped tar whose exit status is checked, so a short write cannot pass as success."
    }
  }
}

output "hook_bytes" {
  description = "Size of the rendered hook, so a plan shows real text was produced"
  value       = length(local.hook)
}

output "decisions" {
  description = "What each configuration decided"
  value = {
    on_active        = module.on.active
    off_active       = module.off.active
    too_small_active = module.too_small_skip.active
    too_small_notes  = join(" / ", module.too_small_skip.notes)
    on_required_gib  = module.on.required_gib
    on_notes         = join(" / ", module.on.notes)
  }
}
