terraform {
  required_version = ">= 1.5.0"
  # No providers on purpose: this renders the boot script and asserts on the text, so it
  # plans on a laptop with no credentials, exactly like tests/boot_hooks and tests/catalog.
}

locals {
  # Rendered with the same key set the two real renderers pass (root main.tf and
  # modules/strata-instance/main.tf). A missing key is a templatefile error, which is itself
  # a useful failure: it means the template grew a variable nobody renders.
  script = replace(templatefile("${path.module}/../../modules/strata-ami/user_data/boot.sh.tpl", {
    model_family         = "nvfp4"
    model                = "Qwen3-Next-80B-A3B-Instruct-NVFP4"
    api_key              = "test-key-not-a-secret"
    use_secrets_manager  = false
    secret_id            = ""
    context_length       = 32768
    kv_quantization      = "q8_0"
    vision_mode          = "off"
    strata_image_tag     = "latest"
    data_volume_device   = "/dev/nvme1n1"
    data_volume_mount    = "/data"
    port                 = 8080
    extra_env            = {}
    tune_mode            = "quick"
    parallel             = null
    gpus                 = ""
    gpu_roles            = ""
    verify_weights       = "sizes"
    health_check_timeout = 600
    ttl_minutes          = 0
    region               = "us-east-1"
    boot_hooks           = []
    pre_start_hooks      = []
  }), "\r\n", "\n")

  lines = split("\n", local.script)

  # Terraform has no string-position function, so ordering is checked by line number: which
  # line first identifies the disk, and which line first formats one.
  identify_lines = [for i, l in local.lines : i if can(regex("Data volume identified", l))]
  format_lines   = [for i, l in local.lines : i if can(regex("mkfs\\.ext4", l))]

  # The seeding script is the other half of the same hazard, and the more expensive half:
  # whatever it snapshots becomes the golden reference every later instance restores from.
  seed = replace(templatefile("${path.module}/../../modules/strata-data-snapshot/download-weights.sh.tpl", {
    model         = "Qwen3-Next-80B-A3B-Instruct-NVFP4"
    model_family  = "nvfp4"
    volume_device = "/dev/sdf"
    volume_id     = "vol-0123456789abcdef0"
  }), "\r\n", "\n")

  seed_lines       = split("\n", local.seed)
  resolve_lines    = [for i, l in local.seed_lines : i if can(regex("resolve_volume\\(\\)", l))]
  seed_mkfs_lines  = [for i, l in local.seed_lines : i if can(regex("mkfs\\.ext4", l))]
  seed_blkid_lines = [for i, l in local.seed_lines : i if can(regex("blkid", l))]

  # Names that belong to these templates. If one survives rendering, a variable was added to a
  # template but not to a renderer, and the shell would receive a literal dollar-brace string
  # where a device name belongs.
  placeholder_names = ["model_family", "volume_device", "volume_id", "data_volume_device", "boot_hooks", "pre_start_hooks", "verify_weights"]
}

resource "terraform_data" "disk_identification" {
  input = length(local.script)

  lifecycle {
    # The bug this exists to prevent: a fixed device name. On instance-store types the
    # ephemeral disk is an NVMe device too and can be /dev/nvme1n1, so the old script could
    # mkfs the instance store, mount an empty /data and download the pack at GPU rates while
    # the restored volume sat unmounted. Identification has to come before formatting.
    precondition {
      # min() takes a varargs list rather than a collection, and a for-comprehension keeps
      # source order, so the first element is already the earliest matching line.
      condition = (
        length(local.identify_lines) > 0 &&
        length(local.format_lines) > 0 &&
        local.identify_lines[0] < local.format_lines[0]
      )
      error_message = "The boot script formats a filesystem before it has identified which disk is the data volume."
    }

    precondition {
      condition     = can(regex("find_data_device\\(\\)", local.script))
      error_message = "Device identification was removed from the boot script; see the comment above find_data_device for why a fixed name is unsafe."
    }

    # Label first, because the volume carries its own identity. Both spellings must be
    # accepted: strata-weights is what the seeding stage formats, strata-data is what volumes
    # created before this change carry. Dropping the second one would make every existing
    # snapshot volume go unrecognised.
    precondition {
      condition = (
        can(regex("blkid -L strata-weights", local.script)) &&
        can(regex("blkid -L strata-data", local.script))
      )
      error_message = "The boot script must look for both filesystem labels, or volumes seeded by the other path stop being found."
    }

    precondition {
      condition     = can(regex("AmazonElasticBlockStore", local.script))
      error_message = "The disk-model test is what separates EBS from instance storage when there is no label yet (a fresh volume)."
    }

    precondition {
      condition     = can(regex("instance storage", local.script))
      error_message = "The last-resort name fallback must still refuse a disk the kernel reports as instance storage."
    }

    # Two candidates means something is genuinely wrong. Guessing would format the wrong
    # disk; stopping is the cheap outcome.
    precondition {
      condition     = can(regex("Refusing to format", local.script))
      error_message = "Ambiguous disk detection must abort rather than pick one."
    }

    # A new volume must be formatted with a label the identification step accepts, or the
    # second boot of the same volume falls through to the weaker signals.
    precondition {
      condition     = can(regex("mkfs\\.ext4 -L strata-weights", local.script))
      error_message = "mkfs must label the volume strata-weights, the label find_data_device looks for first."
    }

    precondition {
      condition     = can(regex("Boot hooks", local.script))
      error_message = "The boot-hook splice must survive edits to the mount step; tests/boot_hooks depends on it."
    }
  }
}

resource "terraform_data" "script_hygiene" {
  input = substr(local.script, 0, 11)

  lifecycle {
    # The renderers strip CRs because a "#!/bin/bash\r" shebang stops cloud-init executing
    # the script, and a Windows working tree checks templates out with CRLF.
    precondition {
      condition     = !can(regex("\r", local.script))
      error_message = "The rendered boot script still contains carriage returns; cloud-init would not execute it."
    }

    precondition {
      condition     = substr(local.script, 0, 11) == "#!/bin/bash"
      error_message = "The boot script must start with its shebang at byte zero."
    }

    # set -e is part of the hook contract: a failing hook aborts the boot.
    precondition {
      condition     = can(regex("set -euo pipefail", local.script))
      error_message = "The hook contract documents set -euo pipefail as active; removing it silently changes what a hook may assume."
    }

    # The seeding script is passed to cloud-init as user_data unmodified by the boot script's
    # own CRLF handling, so a CR here means "#!/bin/bash\r" and a staging instance that never
    # runs the download - then snapshots an empty volume as the golden reference.
    precondition {
      condition     = !can(regex("\r", local.seed))
      error_message = "The rendered seeding script contains carriage returns; its shebang would not execute."
    }
  }
}

resource "terraform_data" "seeding_volume" {
  input = length(local.seed)

  lifecycle {
    # Same hazard as the serving side, larger consequence: this script writes the volume whose
    # snapshot every later instance restores from, and it used to poll for /dev/sdf - a name
    # the attachment API is told to use, which Nitro does not reproduce inside the instance -
    # then format whatever it found, unconditionally.
    precondition {
      condition = (
        length(local.resolve_lines) > 0 &&
        length(local.seed_mkfs_lines) > 0 &&
        local.resolve_lines[0] < local.seed_mkfs_lines[0]
      )
      error_message = "The seeding script must resolve the volume before it formats anything."
    }

    precondition {
      condition = (
        length(local.seed_blkid_lines) > 0 &&
        length(local.seed_mkfs_lines) > 0 &&
        local.seed_blkid_lines[0] < local.seed_mkfs_lines[0]
      )
      error_message = "mkfs must be guarded by a filesystem check: a retried seeding run would otherwise wipe a volume that already holds a completed download."
    }

    precondition {
      condition     = can(regex("/dev/disk/by-id/", local.seed))
      error_message = "The seeding script must resolve the disk by volume id, because the API device name is not the name the OS uses on Nitro."
    }

    precondition {
      condition     = can(regex("instance storage", local.seed))
      error_message = "The legacy-name fallback must refuse a disk the kernel reports as instance storage."
    }

    # A dropped definition here is invisible to Terraform and fatal at boot: mount would
    # target an empty path under set -u.
    precondition {
      condition     = can(regex("DATA_DIR=", local.seed))
      error_message = "DATA_DIR must stay defined in the seeding script; mount would otherwise get an empty target."
    }

    # Proves the renderer really passes volume_id rather than the script defaulting to empty
    # and silently falling back to name polling.
    precondition {
      condition     = can(regex("vol-0123456789abcdef0", local.seed))
      error_message = "volume_id did not reach the rendered seeding script, so resolution would fall back to guessing by name."
    }
  }
}

resource "terraform_data" "rendering_integrity" {
  input = length(local.placeholder_names)

  lifecycle {
    # Both scripts are rendered by templatefile(). A placeholder that survives rendering means
    # someone added a template variable and updated one renderer but not the other, and the
    # shell then receives a literal dollar-brace token where a device name or hook belongs.
    precondition {
      condition = alltrue([
        for name in local.placeholder_names :
        # Bracket classes rather than backslash escapes: [$][{]name[}] matches the literal
        # text "${name}" without any escaping to get wrong, and Go's regexp rejects \" outright.
        !can(regex("[$][{]" + name + "[}]", local.script)) && !can(regex("[$][{]" + name + "[}]", local.seed))
      ])
      error_message = "A template placeholder survived rendering; every renderer of boot.sh.tpl and download-weights.sh.tpl must supply every variable."
    }
  }
}

resource "terraform_data" "splice_order" {
  input = length(local.lines)

  lifecycle {
    # Two splice points, and which one a fragment lands in is the whole contract of
    # pre_start_hooks: before docker run a layer can still change what /data is, after it the
    # model is already loaded and the only thing left to influence is serving behaviour.
    precondition {
      condition = (
        length([for i, l in local.lines : i if can(regex("Pre-start hooks", l))]) > 0 &&
        length([for i, l in local.lines : i if can(regex("docker run -d", l))]) > 0 &&
        length([for i, l in local.lines : i if can(regex("Boot hooks", l))]) > 0 &&
        [for i, l in local.lines : i if can(regex("Pre-start hooks", l))][0] < [for i, l in local.lines : i if can(regex("docker run -d", l))][0] &&
        [for i, l in local.lines : i if can(regex("docker run -d", l))][0] < [for i, l in local.lines : i if can(regex("Boot hooks", l))][0]
      )
      error_message = "The pre-start splice must come before docker run and the post-ready hooks after it; the two contracts are different and the order is what makes them so."
    }

    # wait_loaded() is only defined after docker run, which is exactly why pre-start hooks may
    # not call it. If that ever stops being true the contract comment is a lie.
    precondition {
      condition = (
        length([for i, l in local.lines : i if can(regex("wait_loaded\\(\\) \\{", l))]) > 0 &&
        [for i, l in local.lines : i if can(regex("wait_loaded\\(\\) \\{", l))][0] > [for i, l in local.lines : i if can(regex("docker run -d", l))][0]
      )
      error_message = "wait_loaded() must be defined after the container starts; pre_start_hooks documents that it does not exist at that point."
    }

    # A hook list that is empty must splice to nothing, not to an empty line that a later
    # grep for "did any hook run" would read as yes.
    precondition {
      condition     = !can(regex("strata-instance-store", local.script))
      error_message = "With no hooks rendered the boot script must not contain hook text; the module under test was spliced into the base script."
    }
  }
}

output "script_bytes" {
  description = "Size of the rendered boot script, so a plan shows real text was produced"
  value       = length(local.script)
}

output "identification_lines" {
  description = "How many lines of the script are devoted to working out which disk to mount"
  value = length([
    for line in split("\n", local.script) : line
    if can(regex("find_data_device|blkid|lsblk|AmazonElasticBlockStore|Data volume identified", line))
  ])
}
