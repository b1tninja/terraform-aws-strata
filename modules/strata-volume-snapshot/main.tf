# ─── Promote a volume you already have into a reusable snapshot ─────────────────
# The cheap/heavy split only pays off if a validated volume can become the artefact that
# every later instance restores from. strata-data-snapshot cannot do this: it builds a
# volume by downloading into it, so it never sees a volume that a serving instance already
# tuned and verified.
#
# Why this saves more than it looks like. The engine keeps its presets under
# XDG_STATE_HOME, which the container sets to /data/state (docker/entrypoint.sh:31), so
# tuning results live ON THE DATA VOLUME. A snapshot taken after one real boot therefore
# carries the tuning, and the next instance skips that pass entirely. Snapshotting after
# seeding, before anything has ever run, throws that away.
#
# The manifest stays valid: it deliberately covers only model data and ignores install/
# and state/, which is exactly what a serving boot changes.
variable "name_prefix" {
  description = "Name prefix for the snapshot"
  type        = string
  default     = "strata-weights-promoted"
}

variable "source_volume_id" {
  description = "The volume to snapshot: usually the data volume of an instance that booted, tuned and served successfully. It does not have to be attached."
  type        = string
}

variable "description" {
  description = "Record what was validated on this volume, because a snapshot with no provenance is a guess six weeks later"
  type        = string
  default     = ""
}

variable "enable_fsr" {
  description = <<-EOT
    Enable Fast Snapshot Restore so volumes from this snapshot are fully initialized at
    creation instead of lazily reading from S3.

    This is a standing charge per enabled availability zone for as long as it stays on,
    not a per-use charge, so it is worth deciding deliberately rather than inheriting:
    enable it while you are launching, and set it back to false when you stop. Exact rates
    are on the AWS EBS pricing page and vary by region; this module does not hardcode one.
  EOT
  type        = bool
  default     = false
}

variable "availability_zones" {
  description = "AZs to enable FSR in. Empty means the availability zone of the source volume, which is where a volume in that zone restores fastest."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Additional tags"
  type        = map(string)
  default     = {}
}

data "aws_ebs_volume" "source" {
  filter {
    name   = "volume-id"
    values = [var.source_volume_id]
  }
}

locals {
  fsr_zones = var.enable_fsr ? (length(var.availability_zones) > 0 ? var.availability_zones : [data.aws_ebs_volume.source.availability_zone]) : []

  description = var.description != "" ? var.description : "Strata weights promoted from ${var.source_volume_id} (${data.aws_ebs_volume.source.size} GiB ${data.aws_ebs_volume.source.volume_type} in ${data.aws_ebs_volume.source.availability_zone})"
}

resource "aws_ebs_snapshot" "promoted" {
  volume_id   = var.source_volume_id
  description = local.description

  tags = merge(var.tags, {
    Name               = "${var.name_prefix}-${replace(data.aws_ebs_volume.source.id, "vol-", "")}"
    StrataSourceVolume = var.source_volume_id
    StrataProvenance   = "promoted from a tuned, verified serving volume"
  })
}

resource "aws_ebs_fast_snapshot_restore" "promoted" {
  for_each = toset(local.fsr_zones)

  snapshot_id       = aws_ebs_snapshot.promoted.id
  availability_zone = each.value
}
