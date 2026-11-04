# ─── strata-data-snapshot module outputs (split for standalone use) ────────────

output "staging_instance_id" {
  description = "The staging instance ID (for debugging SSM commands)"
  value       = aws_instance.staging.id
}
