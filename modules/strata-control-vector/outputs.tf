output "boot_hook" {
  description = <<-EOT
    A shell fragment for the core module's boot_hooks input. It runs as root after the
    model reports healthy and expects the base boot script to provide $DATA_MOUNT and
    wait_loaded() - see the contract in modules/strata-ami/user_data/boot.sh.tpl.

    It fetches the pinned vector, verifies each file's SHA-256, records the engine
    arguments as user_args in the model's run config along with the
    sampling.experimental_speed_projection default, restarts the container once so the
    engine starts with the vector loaded, and waits for health again. Any failure aborts
    the boot rather than serving something unverified.
  EOT
  value       = local.fragment
}

output "request_switch" {
  description = <<-EOT
    The per-request sampling key that chooses the behaviour, e.g.
      { "model": "...", "messages": [...], "experimental_speed_projection": true }
    Accepted per request and as a shared default (serve/server.py:8469 SHARED_KEYS), and
    reported back per request as "projection" in /v1/telemetry's history.
  EOT
  value = {
    key            = "experimental_speed_projection"
    config_default = var.default_on
    when_absent    = true
    engine_channel = "cvec=0|1"
  }
}

output "control_vector" {
  description = <<-EOT
    What was pinned, so a reviewer can confirm the exact bytes this deployment fetches
    and the licence ground it stands on. The model, the weights volume and the image are
    identical to a stock deployment: only these few hundred kilobytes differ.
  EOT
  value = {
    source_commit  = local.ref
    download_base  = local.base
    vector_file    = local.vector
    vector_sha256  = local.files[local.vector]
    engine_args    = local.recipe
    licence        = local.licence
    hf_repo        = local.hf_repo
    applicability  = local.applicability
    measured_on    = local.measured_models
    upstream_names = ["control vector", "refusal-direction projection", "experimental speed projection", "uncensored (fork and launcher)"]
  }
}
