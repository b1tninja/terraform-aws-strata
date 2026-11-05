variable "model" {
  description = "Model id this deployment serves. The vector is a direction in one model's activation space, so this decides whether the hook applies at all."
  type        = string
}

variable "model_family" {
  description = "Family of the model above, as Strata names it (qwen, unsloth, nvfp4, ...)"
  type        = string
}

variable "instance_type" {
  description = <<-EOT
    Only used to satisfy the catalog's model/hardware gate while resolving the model
    entry; the deployment's real instance type is validated by the core module. The
    default is the reference box for the pack this vector was made on.
  EOT
  type        = string
  default     = "g7e.8xlarge"
}

variable "default_on" {
  description = <<-EOT
    Whether the projection applies to requests that say nothing about it.

    false (default) keeps the deployment stock: every request runs the original model
    bit for bit and only a caller that passes "experimental_speed_projection": true gets
    the steered behaviour. true makes it the default and a caller opts out with false.

    A loaded vector is on for every request unless the config says otherwise, so leaving
    this false is the conservative choice and costs nothing when off: the kernel skips
    the projection (docs/DETAILS.md:1204-1207).
  EOT
  type        = bool
  default     = false
}

variable "separate_endpoint" {
  description = <<-EOT
    Also append -uncensored to model_name, so the steered configuration reports a
    different name through /v1/models. Useful when a proxy or access-control rule must
    distinguish the two; unnecessary when the caller chooses per request, which is the
    default mode of this hook.
  EOT
  type        = bool
  default     = false
}
