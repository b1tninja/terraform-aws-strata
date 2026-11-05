variable "model" {
  description = "Strata model size id to resolve (see local.models)"
  type        = string
}

variable "model_family" {
  description = "Strata model family to resolve"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type to resolve"
  type        = string
}

variable "volume_headroom_gib" {
  description = "Disk headroom added on top of the download when sizing the data volume"
  type        = number
  default     = null
}

locals {
  volume_headroom_gib = coalesce(var.volume_headroom_gib, local.default_volume_headroom_gib)
}
