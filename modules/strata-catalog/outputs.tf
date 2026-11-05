output "models" {
  description = "The whole model catalog, keyed by size id"
  value       = local.models
}

output "instances" {
  description = "The whole instance catalog, keyed by family"
  value       = local.instances
}

output "model_ids" {
  description = "Every model size id the catalog knows"
  value       = local.model_ids
}

output "family_names" {
  description = "Every model family name Strata accepts"
  value       = local.family_names
}

output "supported_compute_capabilities" {
  description = "Compute capabilities the published Strata engine packages cover"
  value       = local.supported_compute_capabilities
}

output "supported_type_names" {
  description = "Instance types a published Strata engine package can run on"
  value       = local.supported_type_names
}

output "fp4_type_names" {
  description = "Supported instance types that have FP4 tensor cores (sm_120)"
  value       = local.fp4_type_names
}

output "model_entry" {
  description = "Resolved catalog entry for var.model, or null when unknown"
  value       = local.model
}

output "instance_entry" {
  description = "Resolved catalog entry for var.instance_type, or null when unknown"
  value       = local.instance
}

output "known_model" {
  description = "Whether var.model is in the catalog"
  value       = local.known_model
}

output "known_family" {
  description = "Whether var.model_family is a Strata family"
  value       = local.known_family
}

output "family_offers_model" {
  description = "Whether var.model_family offers var.model"
  value       = local.family_offers
}

output "known_instance" {
  description = "Whether var.instance_type is in the catalog"
  value       = local.known_instance
}

output "instance_supported" {
  description = "Whether a published Strata engine package covers var.instance_type"
  value       = try(local.instance.supported, null)
}

output "instance_supports_fp4" {
  description = "Whether var.instance_type has FP4 tensor cores (sm_120)"
  value       = local.instance_supports_fp4
}

output "instance_ram_gib" {
  description = "System RAM of var.instance_type, when known"
  value       = local.instance_ram_gib
}

output "min_volume_gib" {
  description = "Smallest data volume that can hold var.model plus headroom"
  value       = local.min_volume_gib
}

output "recommended_volume_gib" {
  description = "min_volume_gib rounded up to a 10 GiB step"
  value       = local.recommended_volume_gib
}

output "volume_sizes_gib" {
  description = "Recommended data volume size for every catalog model, same rule as recommended_volume_gib"
  value = {
    for id, m in local.models :
    id => ceil((ceil(m.download_gb + coalesce(try(m.prepare_gb, null), 0)) + local.volume_headroom_gib) / 10) * 10
  }
}

output "notes" {
  description = "What this combination implies, including anything that will not work"
  value       = local.notes
}

output "hard_error" {
  description = "True when the combination cannot run at all (var.instance_type has no engine package)"
  value       = local.hard_error
}
