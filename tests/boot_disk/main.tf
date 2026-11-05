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
  }), "\r\n", "\n")

  lines = split("\n", local.script)

  # Terraform has no string-position function, so ordering is checked by line number: which
  # line first identifies the disk, and which line first formats one.
  identify_lines = [for i, l in local.lines : i if can(regex("Data volume identified", l))]
  format_lines   = [for i, l in local.lines : i if can(regex("mkfs\\.ext4", l))]
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
