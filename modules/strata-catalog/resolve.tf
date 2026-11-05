# ─── Resolve a (model, family, instance_type) choice against the catalogs ────────
# The root module turns hard problems into plan-time errors and soft ones into notes,
# so a mis-sized deployment fails here instead of 90 seconds into a booted instance.

locals {
  known_model   = contains(local.model_ids, var.model)
  model         = local.known_model ? local.models[var.model] : null
  known_family  = contains(local.family_names, var.model_family)
  family_offers = try(contains(local.model.families, var.model_family), false)

  known_instance = contains(local.instance_type_names, var.instance_type)
  instance       = local.known_instance ? local.instance_types[var.instance_type] : null

  # Everything the download needs, plus headroom for the pack, tuning data and logs.
  # prepare_gb covers packs the instance converts on first use (NVFP4-QAD: +110 GB).
  min_volume_gib = local.known_model ? (
    ceil(local.model.download_gb + coalesce(try(local.model.prepare_gb, null), 0)) + local.volume_headroom_gib
  ) : null

  # Rounded up to a 10 GiB step so the recommendation reads like a volume size.
  recommended_volume_gib = local.min_volume_gib == null ? null : ceil(local.min_volume_gib / 10) * 10

  instance_ram_gib      = local.known_instance ? local.instance.ram_gib : null
  instance_supports_fp4 = local.known_instance ? local.instance.fp4 : null

  # Hoisted out of the interpolation below: HCL cannot parse a for-expression that
  # contains commas inside "${ }".
  supported_sm_list = join(", ", [for c in local.supported_compute_capabilities : format("sm_%d", floor(c * 10))])

  notes = concat(
    local.known_model ? [] : ["model \"${var.model}\" is not in the catalog; known sizes: ${join(", ", local.model_ids)}"],
    local.known_family ? [] : ["model_family \"${var.model_family}\" is not a Strata family; known families: ${join(", ", local.family_names)}"],
    local.known_model && local.known_family && !local.family_offers ? [
      "family \"${var.model_family}\" does not offer model \"${var.model}\"; it is offered by ${join(", ", local.model.families)}"
    ] : [],
    local.known_instance ? (
      local.instance.supported ? [] : [
        "instance_type \"${var.instance_type}\" (${local.instance.gpu}) cannot run Strata: ${local.instance.note}"
      ]
    ) : ["instance_type \"${var.instance_type}\" is not in the catalog; check its compute capability against ${local.supported_sm_list} yourself"],
    # FP4 only exists on sm_120 (CMakeLists.txt:2189); elsewhere NVFP4 still runs, at
    # 8-bit precision (docs/MODELS.md:244-245). Worth a note either way.
    local.known_model && try(local.model.fp4, false) && local.known_instance ? (
      local.instance_supports_fp4 ? [
        "model \"${var.model}\" gets FP4 tensor cores on ${local.instance.gpu}; consider STRATA_PREFILL_NVFP4=w4a4x2 once measured (docs/NVFP4.md:279-287)"
        ] : [
        "model \"${var.model}\" runs NVFP4 experts at 8-bit precision on ${local.instance.gpu}: only sm_120 has FP4 tensor cores"
      ]
    ) : [],
    # RAM: below the catalog figure Strata offers the RAM-budget mode rather than
    # refusing (docs/NVFP4.md:26-27), so this is a note, not an error.
    local.known_model && local.known_instance && try(local.model.ram_gb, null) != null && local.instance_ram_gib != null ? (
      local.instance_ram_gib >= local.model.ram_gb ? [] : [
        "system RAM is ${local.instance_ram_gib} GiB, below the ${local.model.ram_gb} GiB Strata wants to keep every expert of \"${var.model}\" resident${local.model.budget ? "; it will run in RAM-budget mode with roughly ${local.instance_ram_gib - 24} GiB of experts resident and read the rest from SSD" : "; a larger instance or a smaller size is recommended"}"
      ]
    ) : [],
  )

  hard_error = (
    local.known_model && local.known_instance && !local.instance.supported
  )
}
