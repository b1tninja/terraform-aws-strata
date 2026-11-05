# strata-control-vector

A **boot hook**: it loads a pinned control vector into the engine so the model you
already deployed gains a second behaviour, chosen **per request**, at a cost of
267,552 bytes rather than a second copy of 128 GB of weights.

```hcl
module "steer" {
  source       = "./modules/strata-control-vector"
  model        = "NVFP4"
  model_family = "nvfp4"
}

module "strata" {
  source       = "github.com/b1tninja/terraform-aws-strata"
  model        = "NVFP4"
  model_family = "nvfp4"

  boot_hooks = [module.steer.boot_hook]
}
```

## Names, and which one to use

Three vocabularies describe the same mechanism, so this repository uses the engine's:

| Word | Whose it is | Where |
|---|---|---|
| **control vector** (`controlvector` GGUF, `--control-vector-scaled`) | the engine | `docs/DETAILS.md:1187`, `serve/server.py:1506` |
| **refusal-direction projection** | the vector's own package, quoted by the engine docs | `docs/DETAILS.md:1191` |
| **experimental speed projection** (`ESP`, `cvec=0|1`) | the feature and switch name in this engine | `docs/DETAILS.md:1185`, `SHARED_KEYS` at `server.py:8469` |
| **uncensored** | the fork publishing this vector, and the Windows launcher | `data/uncensor/`, `strata-launcher` |

Nothing here touches the weights. OrcaRouter-style *abliteration* is a different
technique that edits the weights; this does not.

## One endpoint, both behaviours

The vector must be loaded when the engine starts, so the hook restarts the container
once. After that, the running engine serves both configurations:

```bash
# stock, token for token the original model
curl $EP/v1/chat/completions -d '{"model":"m","messages":[...]}'

# projection on for this request only
curl $EP/v1/chat/completions -d '{"model":"m","messages":[...],"experimental_speed_projection":true}'
```

`default_on = false` (the default) writes `"sampling": {"experimental_speed_projection":
false}`, so a deployment stays stock until a caller asks. Switching a conversation drops
the prompt cache once (`docs/DETAILS.md:1206`). `separate_endpoint = true` additionally
renames the model with `-uncensored` for callers that route or gate on `/v1/models`.

## Two gates, both at plan time

- **Lineage** - the vector is one direction in Qwen3.8-Flash-Next's activation space, so
  it means something only for packs derived from those weights (`qwen`, `unsloth`,
  `nvfp4`). Swift 1.5 and the Coder are excluded by upstream because they are other
  weights.
- **Licence** - NVIDIA's own quants are refused: the NVIDIA Open Model License does not
  allow bypassing the model's safety guardrails (`data/uncensor/README.md`, mirrored by
  strata-launcher). That is a permission limit, not a technical one.

`control_vector.applicability` says whether the chosen pack is one of the measured ones
(`NVFP4`, `Q2_0`, `IQ2_XS`, `UD-Q4_K_XL`) or merely offered by upstream's setup.

Removing refusals removes a safety behaviour; you are responsible for what the model
writes with it on. Full walkthrough:
[`examples/nvfp4-uncensored`](../../examples/nvfp4-uncensored).
