# Two deployments, one snapshot

A second *behaviour* costs 267,552 bytes, not a second copy of 128 GB: both instances
restore from the same `weights_snapshot_id` and differ in one hook.

```bash
terraform apply -var="weights_snapshot_id=snap-0abc123..."
```

## When this is the wrong example

If you just want both behaviours, use [`../nvfp4-uncensored`](../nvfp4-uncensored): the
engine takes `experimental_speed_projection` **per request**, so one process serves both
and off is token-for-token stock. This example exists for the cases where sharing a
process is unacceptable:

- one endpoint must be provably unable to serve steered output (no vector loaded at all),
- the two need different network exposure, TTLs or IAM,
- an auditor wants `/v1/models` to name the configuration.

`separate_endpoint = true` on the hook gives the distinct name; the stock deployment
simply never loads a vector, so its engine ignores the key entirely.

## The economics this shows

| Stage | Who pays |
|---|---|
| Download + convert 128 GB | once, when the snapshot is built ([`../full-pipeline`](../full-pipeline)) |
| Restore to a volume | per boot, at snapshot read throughput |
| Stock configuration | GPU hours only |
| Projection configuration | GPU hours + 267,552 B + one container restart |

So an AMI or snapshot holding the weights is a **platform for several serving policies**,
not one model's artefact: one bundled AMI covers both, and you do not need a second.

## Caveats

- Two GPU instances cost two GPU hours. Sharing the snapshot removes storage and download
  cost, not compute. Running both behaviours on one box is what the per-request switch is
  for, and this module launches one container per instance either way.
- `difference.vector_bytes_per_instance` is a literal for this vector, read from the
  GitHub API at the pinned commit, not computed from the catalog.
- Both instances terminate on `ttl_minutes` by default.
