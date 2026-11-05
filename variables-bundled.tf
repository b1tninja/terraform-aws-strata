# ─── Bundled multi-volume AMI ──────────────────────────────────────────────────

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

# ─── Additional Variables (Secrets Manager + Scheduler) ────────────────────────

variable "use_secrets_manager" {
  description = "Store the API key in AWS Secrets Manager (fetched by instance at boot via IAM, not baked into user_data)"
  type        = bool
  default     = false
}

variable "secrets_manager_secret_id" {
  description = "Pre-existing Secrets Manager secret ID or ARN (JSON with api_key field). Overrides auto-generation."
  type        = string
  default     = ""
  sensitive   = true
}

variable "use_eventbridge_scheduler" {
  description = "Use EventBridge Scheduler for reliable TTL termination (survives instance hangs, unlike in-instance shutdown)"
  type        = bool
  default     = true
}
