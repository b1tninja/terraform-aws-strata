variable "enabled" {
  description = "Serve the pack from the instance's local NVMe instead of the EBS data volume. Off by default: it only pays for packs that spill expert pages to SSD, and it has not been measured on real hardware."
  type        = bool
  default     = false
}

variable "scratch_gib" {
  description = "Usable instance-store capacity in GiB on the instance being launched. The catalog records the figure for each family's reference box (strata-catalog's instance_entry reference.nvme_gib); instance-store capacity usually scales with instance size, so pass the value for the size you actually deploy or override it here."
  type        = number
  default     = 0
}

variable "weights_gib" {
  description = "Size of the pack being served in GiB. The catalog's model_entry download_gb is the right number: it is what the seeding stage put on the volume."
  type        = number
  default     = 0
}

variable "min_free_gib" {
  description = "Headroom left on the scratch disk beyond the pack itself, for filesystem overhead and whatever the engine writes next to the model."
  type        = number
  default     = 40
}

variable "mount_point" {
  description = "Where the scratch disk is mounted before it is bind-mounted over the data mount."
  type        = string
  default     = "/mnt/strata-scratch"
}

variable "mutable_paths" {
  description = "Paths under the data mount that must keep living on the EBS volume. They are bind-mounted back over the scratch copy, so tuning state and run settings still land on the volume the promotion step snapshots. Do not add the model directory: copying it is the point."
  type        = list(string)
  default     = ["install", "state", ".strata-manifest"]
}

variable "on_insufficient" {
  description = "What a plan does when the pack plus margin will not fit the scratch disk: \"error\" fails the plan, \"skip\" renders no hook and leaves the instance serving from EBS. Failing is the default because asking for local NVMe on an instance that cannot hold the pack is a configuration mistake, not a preference."
  type        = string
  default     = "error"

  validation {
    condition     = contains(["error", "skip"], var.on_insufficient)
    error_message = "on_insufficient must be \"error\" or \"skip\"."
  }
}
