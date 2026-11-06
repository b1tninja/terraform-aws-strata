# Standing guard: every aws_instance this repository creates must either harden its own metadata
# service and root volume, or inherit both from a launch template that does.
#
# Why: CI's Trivy job caught two HIGH findings on modules/strata-data-snapshot - no IMDSv2, no
# declared root encryption - only after an AVD-AWS-0131 suppression was narrowed to main.tf and
# quietly stopped covering that module. The grep that found the gap took one command; nothing kept
# it from reopening. Discovery is by fileset rather than a hand-written file list, so an instance
# resource added in a new directory is in scope the moment it appears.
#
# No credentials needed: this reads committed source text.

locals {
  root_dir = "${path.module}/../.."

  # Skip anything under a dot-directory: .terraform/ holds provider caches and copied module trees
  # whose source we do not own and must not assert about.
  files = [for f in fileset(local.root_dir, "**/*.tf") : f if !can(regex("(^|/)\\.", f))]

  file_texts = { for f in local.files : f => split("\n", file("${local.root_dir}/${f}")) }

  starts = flatten([
    for f, lines in local.file_texts : [
      for i, l in lines : { f = f, i = i }
      if can(regex("^resource \"aws_instance\"", l))
    ]
  ])

  # Block ends at the first column-zero closing brace (the regex tolerates the trailing CR that
  # split("\n") leaves in a CRLF working copy, and the ^ anchor deliberately ignores indented
  # braces, which belong to nested blocks).
  bounded = [
    for s in local.starts : {
      f = s.f
      i = s.i
      e = try(
        [for k in range(s.i + 1, length(local.file_texts[s.f]) + 1) : k
        if can(regex("^\\}", local.file_texts[s.f][k]))][0],
        length(local.file_texts[s.f]) - 1
      )
    }
  ]

  instances = [
    for x in local.bounded : {
      key  = "${x.f}:${x.i + 1}"
      body = join("\n", [for k, l in local.file_texts[x.f] : l if k >= x.i && k <= x.e])
    }
  ]

  templated = [for inst in local.instances : inst.key if can(regex("launch_template\\s*\\{", inst.body))]

  unhardened_imds = [
    for inst in local.instances : inst.key
    if !contains(local.templated, inst.key) &&
    !can(regex("http_tokens\\s*=\\s*\"required\"", inst.body))
  ]

  unhardened_root = [
    for inst in local.instances : inst.key
    if !contains(local.templated, inst.key) && !(
      can(regex("root_block_device[^{]*\\{", inst.body)) &&
      can(regex("encrypted\\s*=\\s*true", inst.body))
    )
  ]

  # For the launch-template escape, the template in the same file has to actually carry the controls.
  template_files = [
    for f, lines in local.file_texts : f
    if length([for l in lines : l if can(regex("^resource \"aws_launch_template\"", l))]) > 0
  ]

  template_gaps = [
    for f in local.template_files : f
    if !can(regex("http_tokens\\s*=\\s*\"required\"", join("\n", local.file_texts[f])))
  ]
}

terraform {
  required_version = ">= 1.5.0"
}

resource "terraform_data" "instances_hardened" {
  input = length(local.instances)

  lifecycle {
    precondition {
      condition     = length(local.instances) >= 4 && contains(local.files, "main.tf")
      error_message = "This suite found almost no aws_instance resources, or the root main.tf is not among the scanned files, which means discovery broke (glob semantics, renamed paths, or an over-broad dot-filter) rather than that the repository got safer. A guard that silently reads nothing is worse than no guard."
    }

    precondition {
      condition     = length(local.unhardened_imds) == 0
      error_message = "At least one aws_instance does not require IMDSv2 tokens (http_tokens = \"required\") and does not go through a launch template. See modules/strata-data-snapshot/main.tf for the shape of the fix; the finding is AVD-AWS-0028."
    }

    precondition {
      condition     = length(local.unhardened_root) == 0
      error_message = "At least one aws_instance declares no root_block_device and is not launch-template based, so its root volume is encrypted only if the account's regional default says so - which Terraform cannot see. AVD-AWS-0131."
    }

    precondition {
      condition     = length(local.template_gaps) == 0
      error_message = "An instance relied on a launch template for hardening, but no aws_launch_template in that file sets http_tokens = \"required\". The launch_template escape only holds if the template actually carries the control."
    }
  }
}

output "instance_hardening" {
  description = "Every instance resource examined, and how each was considered covered"
  value = {
    files_scanned         = length(local.files)
    instances_found       = length(local.instances)
    via_launch_template   = local.templated
    imds_gaps             = local.unhardened_imds
    root_device_gaps      = local.unhardened_root
    launch_template_files = local.template_files
  }
}
