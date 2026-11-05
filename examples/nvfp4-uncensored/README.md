# One model, two behaviours

The point of a control vector: **the model is not the thing that changes.**

| | stock | projection |
|---|---|---|
| weights | 128 GB NVFP4 GPTQ | *the same* 128 GB |
| volume / snapshot | 180 GiB | *the same* 180 GiB |
| image | `ghcr.io/niko1221/strata` | *the same* |
| process | **the same container** | *the same* |
| chosen by | — | `"experimental_speed_projection": true` **per request** |
| extra bytes | — | **267,552 B** |

```hcl
module "steer" {
  source       = "../../modules/strata-control-vector"
  model        = "NVFP4"
  model_family = "nvfp4"
}

module "strata" {
  source       = "github.com/b1tninja/terraform-aws-strata"
  model        = "NVFP4"
  model_family = "nvfp4"
  boot_hooks   = [module.steer.boot_hook]
}
```

## Three names for one mechanism

Upstream's docs and this engine use different words, which is worth knowing before you
search for them:

| Term | Where it comes from |
|---|---|
| **control vector**, `--control-vector-scaled`, GGUF `controlvector` | the engine |
| **refusal-direction projection** | the vector's package, quoted at `docs/DETAILS.md:1191` |
| **experimental speed projection** / `ESP` / `cvec=0\|1` | this engine's feature and per-request key (`SHARED_KEYS`, `server.py:8469`) |
| **uncensored** | the fork publishing this vector and the Windows launcher |

The example keeps the directory name `nvfp4-uncensored` because that is what people
search for. Note that **OrcaRouter-style abliteration is a different technique** - it
edits the weights; this does not touch them.

## What happens at boot

The hook runs after the model reports healthy:

1. Fetch the vector from a **pinned commit**, verify each file's **SHA-256**; a mismatch
   is deleted and the boot fails rather than serving something unverified.
2. `chmod -R a+rX` so uid 10001 (the engine user) can read it.
3. Record the engine arguments as `user_args` — the one run-config field that survives
   the engine rewriting the file — and set `sampling.experimental_speed_projection`.
4. Restart the container **once**, because a vector is only loaded when the engine
   starts (`server.py:1507`: "an engine without one ignores the key"). After that,
   choosing the behaviour per request costs nothing.

## Measured, not asserted

From `data/uncensor/README.md` at the pinned commit, against the stock model:

| | stock | this vector | upstream's ESP vector | abliteration |
|---|---|---|---|---|
| refusals, thinking on (EN held-out) | 30/30 | **0/30** | 1/30 | – |
| KL vs stock / same top token | 0 / 100% | **0.026** / 94.4% | 0.043 / 93.1% | 0.047 / 92.9% |
| decode tokens/s | 158.8 | 159.0 | 158.4 | 141.1 / 161.7 |

Off, a request is **token for token** the stock model's: the kernel skips the projection
(`docs/DETAILS.md:1207`). Switching mid-conversation drops the prompt cache once.

## Two gates, at plan time

- **Lineage** — the vector is one direction in Qwen3.8-Flash-Next's activation space.
  Upstream measured it on `qwen-nvfp4-gptq`, ISTA's Q2_0 and IQ2_XS, and Unsloth's
  UD-Q4_K_XL — "works unchanged on all three quants, with no rescaling" — and offers it
  for the whole `qwen` family. Swift 1.5 and the Coder are excluded: other weights.
- **Licence** — NVIDIA's own quants are refused, because the NVIDIA Open Model License
  does not allow bypassing the model's safety guardrails. That is a **permission** limit,
  not a technical one; the same direction runs on the Qwen-licensed packs.

`control_vector.applicability` tells you whether your pack is one of the measured ones or
merely offered. Removing refusals removes a safety behaviour: you are responsible for
what the model writes with it on.

## If you need two endpoints instead

Set `separate_endpoint = true` and the hook also appends `-uncensored` to `model_name`, so
`/v1/models` distinguishes the two — useful when a proxy or ACL keys on the name. For
running two instances off one snapshot, see
[`../one-snapshot-two-configs`](../one-snapshot-two-configs); for separate stacks,
[`../layered-stacks`](../layered-stacks).
