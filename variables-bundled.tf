# ─── New: Bundled multi-volume AMI ─────────────────────────────────────────────

variable "use_bundled_ami" {
  description = "If true, the AMI already contains the model weights as a data volume in its block device mapping. No separate weights_snapshot_id needed."
  type        = bool
  default     = false
}

variable "bundled_data_volume_device" {
  description = "Device name the AMI's data volume maps to (from the AMI's block device mapping)"
  type        = string
  default     = "/dev/sdb"
}
