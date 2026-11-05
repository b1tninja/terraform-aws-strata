# ─── Control-vector hook: one model, two behaviours ─────────────────────────────
# A hook is a self-contained piece of deployment behaviour that the core module splices
# into the boot script after the model reports healthy. The core has no idea what a
# control vector is: it takes boot_hooks, a list of shell fragments. This module
# produces one, plus the audit record of the bytes it fetches.
#
# What the thing actually is (upstream's words, not mine):
#   A control vector in GGUF `controlvector` format - one direction of 2,560 values per
#   layer. After each of the steered layers the engine removes that layer's refusal
#   direction from every hyper-connection residual stream (h -= s (h . v) v). Upstream
#   calls the feature experimental speed projection and the vector's own package
#   describes it as a refusal-direction projection; the model then "declines far fewer
#   requests" (docs/DETAILS.md:1187-1194). The fork that publishes this particular
#   vector, and the Windows launcher, call the resulting configuration "uncensored".
#   All three names refer to the same mechanism, and none of it touches the weights.
#
# Why this is a hook and not a flag on the core: what changes between the two behaviours
# is 267,552 bytes, not the 128 GB of routed experts. Steering policy is expected to
# grow - other vectors, other layer ranges, other licence rules - and that growth should
# never touch the core module or the shared boot script.
#
# Why per request rather than one deployment each: the engine reads
# sampling.experimental_speed_projection per request and sends the engine `cvec=0|1`
# (serve/server.py:1506-1510; the key is in SHARED_KEYS at :8469). Off, the request is
# token-for-token the stock model's. One running engine therefore serves both
# configurations - the only thing that must happen at boot is that the vector gets
# loaded, which needs the engine to start with it (server.py:1507: "an engine without
# one ignores the key"). Hence exactly one restart.
locals {
  # Pinned upstream commit. The vector is not redistributed here: the instance fetches
  # it over HTTPS and verifies the digest, and a mismatch aborts the boot.
  ref  = "a1ad595440468ededd8b87cf46a6906310930170"
  base = "https://raw.githubusercontent.com/sergqwer/strata-nvfp4/${local.ref}/data/uncensor"

  # name = sha256. Sizes (267552 / 4792 / 5664 bytes) cross-checked against the GitHub
  # API at this ref on 2026-11-04. These are the digests strata-launcher checks with
  # Get-FileHash (SHA-256) at strata-launcher.ps1:3320-3323; the recipe is its
  # $UNCENSOR_ARGS at :3325-3328.
  #
  # Do NOT change sha256sum to sha1sum because a document says otherwise:
  # strata-launcher's README.md:403, docs/using.md:268 and setup.py:4416 all call these
  # "SHA-1", but that prose is stale - the values are 64 hex characters and the code
  # hashes with Get-FileHash. Likewise docs/using.md:262 describes the recipe as
  # "--cvec-mode remove --cvec-dir pos-neg" while the shipped $UNCENSOR_ARGS uses
  # "project" and "per-layer". The code is what was measured.
  files = {
    "qwen-nvfp4-gptq-uncensored.gguf" = "a2ec3e999724022a55d48d30822bd10b1b25916ccc221013a119a674d06a46b5"
    "qwen-nvfp4-gptq-uncensored.json" = "83858b5db79b78e8790fc9e0c05bf7ae2681640b1248372dffda517a038d89c1"
    "README.md"                       = "7fb4156ba62d9c6d49faa826b5300e9992c2e3e88f947fe839f90163d754a273"
  }

  vector = "qwen-nvfp4-gptq-uncensored.gguf"

  # Engine recipe as measured for this vector: layers 8-33 from the vector's own
  # metadata, project mode, per-layer direction, scale 1.0. Upstream's own vector
  # (data/experimental-speed-projection/, docs/DETAILS.md:1200-1201) uses layers 4-44
  # and is a different direction: do not mix them.
  recipe = [
    "--control-vector-scaled", "/data/control-vectors/${local.vector}:1.0",
    "--control-vector-layer-range", "8", "33",
    "--cvec-mode", "project", "--cvec-dir", "per-layer",
  ]
}

# Where the vector was actually measured, per data/uncensor/README.md at the pinned ref:
# "Made and measured on qwen-nvfp4-gptq; measured too on ISTA's Q2_0 and IQ2_XS (setup
# offers it for the whole qwen family...) and on Unsloth's UD-Q4_K_XL".
locals {
  measured_models = ["NVFP4", "Q2_0", "IQ2_XS", "UD-Q4_K_XL"]

  # It is a direction in Qwen3.8-Flash-Next's activation space, so any pack derived from
  # those weights can use it. Swift 1.5 and the Coder are excluded because they are other
  # weights, and the DeepSeek/Gyro lines are not this model at all.
  lineage_families = ["qwen", "unsloth", "nvfp4"]

  licence = try(module.catalog.model_entry.license, "")
  hf_repo = try(module.catalog.model_entry.hf_repo, "")

  lineage_ok = contains(local.lineage_families, var.model_family)

  # Not a technical limit - a permission one. data/uncensor/README.md: "Never for
  # qwen-nvidia-nvfp4: the NVIDIA Open Model License does not allow bypassing the
  # model's safety guardrails." Same rule as strata-launcher's Get-UncensorRefusal.
  licence_ok = local.licence == "qwen"

  applicability = contains(local.measured_models, var.model) ? "measured" : "offered by upstream, not measured for this model"
}

module "catalog" {
  source = "../strata-catalog"

  model         = var.model
  model_family  = var.model_family
  instance_type = var.instance_type
}

# Presence of the hook is the opt-in: there is no enable flag. Both gates run at plan
# time, so an inapplicable or unpermitted pack fails before anything is created.
resource "terraform_data" "gate" {
  input = {
    model         = var.model
    model_family  = var.model_family
    licence       = local.licence
    vector_sha256 = local.files[local.vector]
  }

  lifecycle {
    precondition {
      condition     = local.lineage_ok
      error_message = "This control vector is a direction in Qwen3.8-Flash-Next's activation space. It applies to packs derived from those weights (the qwen, unsloth and nvfp4 families); Swift 1.5 and the Coder are other weights, so the direction means nothing for them, exactly as upstream excludes them."
    }

    precondition {
      condition     = local.licence_ok
      error_message = "The selected pack is not under a licence that permits adding a refusal-removing control vector. NVIDIA's own NVFP4 and FP4-Local quants are under the NVIDIA Open Model License/Agreement, which does not allow bypassing the model's safety guardrails. This is a permission limit, not a technical one: the same direction works on the Qwen-licensed quants."
    }
  }
}

locals {
  # CRLF-stripped for the same reason the boot script is. A Windows working tree checks
  # templates out with CR+LF when core.autocrlf is true (git ls-files --eol reports i/lf
  # w/crlf here), and this text is spliced verbatim into user_data, where bash reads
  # "command\r" as a command named "command\r". trimspace() does not help: it only reaches the
  # ends of the fragment, not the interior line endings.
  fragment = trimspace(replace(templatefile("${path.module}/templates/apply-vector.sh.tpl", {
    base              = local.base
    files             = local.files
    args_json         = jsonencode(local.recipe)
    default_on        = var.default_on
    separate_endpoint = var.separate_endpoint
    suffix            = "-uncensored"
    commit_ref        = local.ref
  }), "\r\n", "\n"))
}

