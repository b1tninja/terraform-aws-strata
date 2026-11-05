# ─── What the plan can decide without booting anything ─────────────────────────
locals {
  # A catalog lookup that returns null for an unknown model or instance is the normal way a
  # number goes missing here, so 0 means "nobody told us" rather than "no room". The runtime
  # guard in the hook still checks free space; this is about not lying at plan time.
  has_numbers = var.scratch_gib > 0 && var.weights_gib > 0

  needed_gib   = ceil(var.weights_gib)
  required_gib = local.needed_gib + var.min_free_gib
  headroom_gib = var.scratch_gib - local.required_gib
  fits         = var.scratch_gib >= local.required_gib

  # "Won't fit and the caller asked for an error" is raised by the guard below, so anything
  # that reaches here is either a fit, an unknown size (the hook checks at runtime), or a
  # deliberate skip.
  blocked = var.enabled && local.has_numbers && !local.fits && var.on_insufficient == "error"
  active  = var.enabled && !(local.has_numbers && !local.fits)

  mutable_list = join(" ", var.mutable_paths)
  tar_excludes = join(" ", [for p in var.mutable_paths : "--exclude=./${p}"])

  # CRLF-safe for the same reason the boot script is: a Windows working tree checks templates
  # out with CR+LF, and user_data is executed as-is.
  hook = local.active ? replace(templatefile("${path.module}/templates/seed-scratch.sh.tpl", {
    mount_point  = var.mount_point
    weights_gib  = local.needed_gib
    min_free_gib = var.min_free_gib
    mutable_list = local.mutable_list
    tar_excludes = local.tar_excludes
  }), "\r\n", "\n") : ""
}

resource "terraform_data" "fit" {
  input = {
    scratch_gib     = var.scratch_gib
    weights_gib     = var.weights_gib
    required_gib    = local.required_gib
    on_insufficient = var.on_insufficient
  }

  lifecycle {
    # The failure this prevents is a slow, silent one: the copy runs, the disk fills, tar
    # reports a short write, and the boot logs a skip and serves from EBS anyway - correct,
    # but the operator learns about the misfit from a boot log on a rented GPU instead of
    # from terraform plan.
    precondition {
      condition     = !local.blocked
      error_message = "instance-store: the pack plus ${var.min_free_gib} GiB headroom needs ${local.required_gib} GiB and this instance advertises ${var.scratch_gib} GiB. Choose a larger instance, a smaller pack, or set on_insufficient = \"skip\" to let the runtime decide."
    }

    # mount_point has to survive being pasted into a shell assignment; a space or quote there
    # would split the command line rather than fail loudly.
    precondition {
      condition     = can(regex("^/[A-Za-z0-9_/.-]*$", var.mount_point))
      error_message = "mount_point must be an absolute path with no spaces or shell metacharacters; it is interpolated into a shell assignment."
    }

    # Same reasoning for the paths that become tar --exclude arguments and bind targets.
    precondition {
      condition     = alltrue([for p in var.mutable_paths : can(regex("^[A-Za-z0-9._-]+$", p))])
      error_message = "mutable_paths must be single path segments without slashes or shell metacharacters."
    }
  }
}
