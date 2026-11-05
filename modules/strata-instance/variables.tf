variable "uncensor" {
  description = <<-EOT
    Control-vector settings rendered into the boot script, as produced by the root
    module's uncensor.tf. Left null, the instance serves the model exactly as
    published; when set with enabled = true, the boot script fetches and verifies the
    vector, records it as user_args in the model's run config, and restarts the
    container so the same weights serve the uncensored configuration.
  EOT
  type = object({
    enabled   = bool
    base      = string
    vector    = string
    file_pins = string
    args_json = string
  })
  default = null
}
