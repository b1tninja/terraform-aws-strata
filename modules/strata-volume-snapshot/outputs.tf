output "snapshot_id" {
  description = "Restore future instances from this instead of the freshly seeded snapshot, and they inherit the tuning"
  value       = aws_ebs_snapshot.promoted.id
}

output "volume_size" {
  description = "Size of the source volume, so a serving stack can size its data volume to match"
  value       = aws_ebs_snapshot.promoted.volume_size
}

output "source_volume_id" {
  description = "Where this snapshot came from"
  value       = var.source_volume_id
}

output "fsr_availability_zones" {
  description = "AZs with Fast Snapshot Restore enabled, and therefore accruing the standing FSR charge"
  value       = keys(aws_ebs_fast_snapshot_restore.promoted)
}
