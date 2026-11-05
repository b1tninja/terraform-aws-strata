# One model, two configurations

The point of the control-vector method: **the model is not the thing that changes.**

| | stock | uncensored |
|---|---|---|
| weights | 128 GB NVFP4 GPTQ | *the same* 128 GB |
| volume / snapshot | 180 GiB | *the same* 180 GiB |
| image | `ghcr.io/niko1221/strata` | *the same* |
| extra bytes | — | **267,552 B** control vector |
| served name | `strata-nvfp4-nvfp4` | `strata-nvfp4-nvfp4-uncensored` |

```hcl
model        = "NVFP4"
model_family = "nvfp4"
uncensored   = true      # false = the model exactly as published
```

## What happens at boot

`[7/7]` in the boot script:

1. Fetch the vector from a **pinned commit** and verify its **SHA-256**; a mismatch is
   deleted and the boot fails rather than serving something unverified.
2. `chmod -R a+rX` so uid 10001 (the engine user inside the container) can read it.
3. Merge it into the model's run config as `user_args`, and append `-uncensored` to
   `model_name`. `serve/server.py` merges `user_args` over the generated engine
   arguments at every start, which is why this survives the engine rewriting the rest
   of the file.
4. `docker restart strata`, then wait for `/health` again (~1 min for the second load).

## Pins and why they look wrong

`terraform output control_vector` prints the commit, URL, digest and the exact engine
arguments. Upstream's *prose* calls the digest "SHA-1"
(`strata-launcher/docs/using.md:268`, `README.md:403`) and the recipe
`--cvec-mode remove --cvec-dir pos-neg` (`using.md:262`). Both are stale: the shipped
`$UNCENSOR_ARGS` / `$UNCENSOR_CHECKSUMS` at `strata-launcher.ps1:3320-3328` use
`project` + `per-layer` and 64-hex SHA-256 checked with `Get-FileHash`. This module
follows the code, which is what was measured.

## Gate

`uncensored = true` is rejected at **plan time** unless the pack is the NVFP4 GPTQ one
the vector was made and measured on, **and** its licence permits it. `NVFP4-NVIDIA` and
`NVFP4-QAD` are under the NVIDIA Open Model License, which does not allow bypassing the
model's safety guardrails — strata-launcher refuses them, so does this module.

## Cost

One GPU-hour more than the stock deployment, not a second model: nothing is
re-downloaded, and one snapshot or AMI holding the weights serves both configurations
(see [`../one-snapshot-two-configs`](../one-snapshot-two-configs)).
