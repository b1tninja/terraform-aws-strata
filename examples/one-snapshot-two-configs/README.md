# Two configurations, one snapshot

Shows the property that makes the control-vector method worth deploying: **a second
behavioural configuration costs 261 KiB, not a second copy of 128 GB.**

Both `module "stock"` and `module "uncensored"` restore from the same
`weights_snapshot_id`, and differ in exactly one argument. `/v1/models` on the two
endpoints reports `strata-nvfp4-nvfp4` and `strata-nvfp4-nvfp4-uncensored`.

```bash
terraform apply -var="weights_snapshot_id=snap-0abc123..."
```

## The economics this implies

| Stage | Who pays |
|---|---|
| Download + convert 128 GB | once, in the snapshot build ([`../full-pipeline`](../full-pipeline)) |
| Restore to a volume | per boot, at snapshot read throughput |
| Stock configuration | GPU hours only |
| Uncensored configuration | GPU hours + 261 KiB + one container restart |

So an AMI or snapshot that holds the weights is a **platform for several serving
policies**, not one model's artefact. If you build one bundled AMI, you do not need a
second one for the uncensored variant.

## Caveats, stated plainly

- Two GPU instances cost two GPU hours. Sharing the snapshot removes the storage and
  download cost, not the compute. To run both configurations on one box you would need
  two containers and enough VRAM/RAM for two loaded engines; this module launches one
  container per instance and does not claim otherwise.
- The `difference` output's `extra_bytes_per_instance` is a literal for this vector,
  read from the GitHub API at the pinned commit — it is not computed from the catalog.
- Both instances terminate on `ttl_minutes` by default.
