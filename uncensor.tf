# ─── Uncensored variant: one model, two configurations ──────────────────────────
# The routed experts are the expensive part (NVFP4 GPTQ is 128 GB). The refusal
# direction that stops the model declining requests is a 261 KiB control vector
# applied to the engine at load time, so the same weights on the same volume can
# serve two configurations:
#
#   uncensored = false -> strata-nvfp4-nvfp4            (the model as published)
#   uncensored = true  -> strata-nvfp4-nvfp4-uncensored (same 128 GB, steered)
#
# Nothing is re-downloaded and nothing is added to the image: the instance fetches
# the vector, verifies its SHA-256, and records it as "user_args" in the model's run
# config, which serve/server.py merges over the generated engine arguments on every
# start (see strata_control/user_args.py:1-9 and serve/server.py:3250-3253). That is
# the same mechanism strata-launcher's "Uncensored variant..." uses.
#
# The vector is NOT redistributed here. It is downloaded from a pinned commit and
# checked against the SHA-256 the launcher documents; a mismatch is deleted.

locals {
  uncensor_ref  = "a1ad595440468ededd8b87cf46a6906310930170"
  uncensor_base = "https://raw.githubusercontent.com/sergqwer/strata-nvfp4/${local.uncensor_ref}/data/uncensor"

  # name = sha256. Sizes (267552 / 4792 / 5664 bytes) verified against the GitHub API
  # at the pinned ref on 2026-11-04. These are the digests strata-launcher checks with
  # Get-FileHash (SHA-256) at strata-launcher.ps1:3320-3323, and the recipe is its
  # $UNCENSOR_ARGS at :3325-3328.
  #
  # Do NOT change sha256sum to sha1sum because a document says otherwise:
  # strata-launcher's README.md:403, docs/using.md:268 and setup.py:4416 all call these
  # "SHA-1", but that prose is stale - the values are 64 hex characters and the code
  # hashes with Get-FileHash, which is SHA-256. Likewise docs/using.md:262 describes the
  # recipe as "--cvec-mode remove --cvec-dir pos-neg" while the shipped $UNCENSOR_ARGS
  # uses "project" and "per-layer". The code is what was measured.
  uncensor_files = {
    "qwen-nvfp4-gptq-uncensored.gguf" = "a2ec3e999724022a55d48d30822bd10b1b25916ccc221013a119a674d06a46b5"
    "qwen-nvfp4-gptq-uncensored.json" = "83858b5db79b78e8790fc9e0c05bf7ae2681640b1248372dffda517a038d89c1"
    "README.md"                       = "7fb4156ba62d9c6d49faa826b5300e9992c2e3e88f947fe839f90163d754a273"
  }

  uncensor_vector = "qwen-nvfp4-gptq-uncensored.gguf"

  # Engine recipe as measured for this vector: layers 8-33 (its own metadata), project
  # mode, per-layer direction. Deliberately NOT --experimental-speed-projection, which
  # hard-codes 4-44 (setup.py:10296) and is a different vector.
  uncensor_recipe = [
    "--control-vector-scaled", "/data/uncensor/${local.uncensor_vector}:1.0",
    "--control-vector-layer-range", "8", "33",
    "--cvec-mode", "project", "--cvec-dir", "per-layer",
  ]


  uncensor_enabled = var.uncensored

  # The vector was made and measured on one pack. strata-launcher refuses anything
  # else, including NVIDIA's packs, whose licence does not allow bypassing the
  # model's safety guardrails (docs/using.md:168-170; setup.py:477-497).
  uncensor_model_ok   = try(module.catalog.model_entry.hf_repo, "") == "Maximilian228/Qwen3.8-Flash-Next-NVFP4-GPTQ-Strata"
  uncensor_licence_ok = try(module.catalog.model_entry.license, "") == "qwen"

  uncensor_file_pins = join(" ", [for name, digest in local.uncensor_files : "${name}:${digest}"])

  # One object so the nested instance module needs a single input instead of five.
  uncensor_block = {
    enabled   = local.uncensor_enabled
    base      = local.uncensor_base
    vector    = local.uncensor_vector
    file_pins = local.uncensor_file_pins
    args_json = jsonencode(local.uncensor_recipe)
  }
}


resource "terraform_data" "uncensor_preflight" {
  count = local.uncensor_enabled ? 1 : 0

  input = {
    model         = var.model
    vector_sha256 = local.uncensor_files[local.uncensor_vector]
  }

  lifecycle {
    precondition {
      condition     = local.uncensor_model_ok
      error_message = "uncensored = true is only offered for the NVFP4 GPTQ pack (model = \"NVFP4\", family = \"nvfp4\"): that is the weights set the vector was made and measured on. Other models are refused, exactly as strata-launcher refuses them."
    }

    precondition {
      condition     = local.uncensor_licence_ok
      error_message = "The pack selected is not under a licence that permits adding a refusal-removing control vector. NVIDIA's NVFP4 and FP4-Local packs are licensed under the NVIDIA Open Model License/Agreement, which does not allow bypassing the model's safety guardrails."
    }
  }
}
