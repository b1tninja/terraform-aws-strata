output "pre_start_hook" {
  description = "The rendered boot text, or an empty string when the layer is off or has been skipped for not fitting."
  value       = local.hook
  sensitive   = false
}

output "pre_start_hooks" {
  description = "Ready to pass straight to the root or instance module: pre_start_hooks = module.scratch.pre_start_hooks"
  value       = local.active ? [local.hook] : []
}

output "active" {
  description = "Whether the hook will actually be spliced into the boot script"
  value       = local.active
}

output "fits" {
  description = "Whether the pack plus margin fits the scratch disk as described"
  value       = local.fits
}

output "required_gib" {
  description = "Pack size plus headroom, the number scratch_gib is compared against"
  value       = local.required_gib
}

output "notes" {
  description = "What the plan decided, for whoever reads the plan output"
  value = concat(
    var.enabled ? [] : ["instance-store: off, serving from the EBS volume"],
    var.enabled && !local.has_numbers ? ["instance-store: scratch_gib or weights_gib is 0, so the fit cannot be checked"] : [],
    var.enabled && local.has_numbers && local.fits ? ["instance-store: pack fits with ${local.headroom_gib} GiB to spare"] : [],
    var.enabled && local.has_numbers && !local.fits && var.on_insufficient == "skip" ? ["instance-store: pack needs ${local.required_gib} GiB, disk has ${var.scratch_gib}; skipping and serving from EBS"] : []
  )
}
