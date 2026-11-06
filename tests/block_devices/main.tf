# Assertion suite for block-device encryption in the root module.
#
# Why this exists as a test rather than a comment: .trivyignore.yaml suppresses AVD-AWS-0131
# ("instance with unencrypted block device") for main.tf, on the grounds that aws_instance.strata
# and strata_spot declare no block devices and inherit every mapping from aws_launch_template.strata,
# where each one is explicitly encrypted. That suppression is only correct while both halves of the
# sentence hold. If someone later adds an inline root_block_device or ebs_block_device to those
# instances, or adds an ebs block that forgets encrypted, the ignore quietly hides a real finding -
# which is the failure mode of every suppression, and the reason this file exists.
#
# Runs with no AWS credentials: it reads committed source text, and CI discovers it automatically
# because the test matrix is derived from the tests/ directory rather than listed by hand.

locals {
  root  = file("${path.module}/../../main.tf")
  lines = split("\n", local.root)

  # Line indices, so an ebs block can be paired with the encrypted line that belongs to it.
  ebs_open        = [for i, l in local.lines : i if can(regex("^\\s*ebs \\{", l))]
  encrypted       = [for i, l in local.lines : i if can(regex("^\\s*encrypted\\s*=\\s*true", l))]
  encrypted_false = [for i, l in local.lines : i if can(regex("^\\s*encrypted\\s*=\\s*false", l))]

  # An ebs block counts as covered when some encrypted = true appears within the 12 lines after it,
  # which is the whole block for every mapping in this file and short enough that a block cannot
  # borrow a neighbouring block's setting.
  uncovered = [
    for i in local.ebs_open : i
    if length([for e in local.encrypted : e if e > i && (e - i) <= 12]) == 0
  ]

  inline_devices = [
    for i, l in local.lines : i
    if can(regex("^\\s*root_block_device \\{", l)) || can(regex("^\\s*ebs_block_device \\{", l)) ||
    can(regex("^\\s*dynamic \"(root_block_device|ebs_block_device)\"", l))
  ]
}

terraform {
  required_version = ">= 1.5.0"
}

resource "terraform_data" "every_ebs_mapping_encrypted" {
  input = length(local.lines)

  lifecycle {
    precondition {
      condition     = length(local.ebs_open) >= 4
      error_message = "Expected at least four ebs block devices in main.tf (root plus the snapshot, bundled-AMI and empty-volume branches). Fewer means the launch template's block-device layout changed; re-read the AVD-AWS-0131 suppression in .trivyignore.yaml before trusting it."
    }

    precondition {
      condition     = length(local.uncovered) == 0
      error_message = "At least one ebs block in main.tf has no encrypted = true within its own block. With AVD-AWS-0131 ignored for this file, Trivy cannot tell you this - which is exactly why the check lives here instead."
    }

    precondition {
      condition     = length(local.encrypted_false) == 0
      error_message = "Something sets encrypted = false explicitly in main.tf, overriding the module's default."
    }

    # Coupled to the suppression: instances inherit from the launch template, and the ignore says
    # so. Inline devices on those instances would make the suppression wrong while keeping CI green.
    precondition {
      condition     = length(local.inline_devices) == 0
      error_message = "main.tf now declares an inline root_block_device or ebs_block_device on an aws_instance. The AVD-AWS-0131 entry in .trivyignore.yaml claims those instances declare no block devices and inherit encrypted mappings from aws_launch_template.strata - that justification no longer applies, so remove or narrow the ignore in the same change."
    }
  }
}

output "checked" {
  description = "What this suite looked at, so a green run is not mistaken for nothing having been read"
  value = {
    main_tf_lines              = length(local.lines)
    ebs_blocks                 = length(local.ebs_open)
    encrypted_settings         = length(local.encrypted)
    ebs_blocks_unencrypted     = length(local.uncovered)
    inline_device_declarations = length(local.inline_devices)
  }
}
