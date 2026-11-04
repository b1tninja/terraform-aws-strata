# ─── AMI Creation ─────────────────────────────────────────────────────────────
# aws_ami_from_instance creates an AMI by snapshotting ALL attached EBS volumes.
# Because EBS snapshots are INCREMENTAL, rebuilding the AMI when only the root
# changes (new Docker image, OS patches) costs ~$0 extra for the 250GB of
# unchanged weight data. The new data snapshot references the same S3 blocks.

resource "aws_ami_from_instance" "strata" {
  name                    = "${var.name_prefix}-${var.model}"
  description             = "Strata AMI: model ${var.model} (${var.model_family}), image ${var.strata_image_tag}. Multi-volume: root=OS+Docker+Strata, /dev/sdb=weights."
  source_instance_id      = aws_instance.staging.id
  snapshot_without_reboot = false

  tags = merge(local.common_tags, {
    Name      = "${var.name_prefix}-${var.model}"
    Model     = var.model
    StrataTag = var.strata_image_tag
    Volume    = "bundled"
  })

  lifecycle {
    ignore_changes = [name, description]
  }
}

# ─── Outputs ───────────────────────────────────────────────────────────────────

output "ami_id" {
  description = "The bundled multi-volume AMI ID"
  value       = aws_ami_from_instance.strata.id
}

output "root_snapshot_id" {
  description = "Root volume snapshot ID from the AMI"
  value       = aws_ami_from_instance.strata.root_snapshot_id
}

output "staging_instance_id" {
  value = aws_instance.staging.id
}
