# strata-volume-snapshot

Turns a volume you already trust into the snapshot every later instance restores from.

```hcl
module "promote" {
  source = "./modules/strata-volume-snapshot"

  source_volume_id = "vol-0abc123"          # the data volume of a serving instance
  description      = "NVFP4 tuned on g7.8xlarge, control-vector hook validated 2026-11-05"
}

# later deployments
weights_snapshot_id = module.promote.snapshot_id
```

## Why this exists

`strata-data-snapshot` builds a volume by downloading into it, so the snapshot it produces
has never run anything. That throws away two things a real boot produces:

- **Tuning.** The engine keeps presets under `XDG_STATE_HOME`, and the container sets that
  to `/data/state` (`docker/entrypoint.sh:31`) - on the data volume. Snapshot after one
  genuine boot and the next instance skips the tuning pass; snapshot before it and every
  instance pays for that pass on an expensive card.
- **Proof.** A volume that booted, loaded and answered a request has also proven the run
  settings, the card assignment and any boot hook. Promoting it makes the next deployment a
  repeat of something known rather than a first run.

The weights manifest written at seed time stays valid: it deliberately covers only model
data and ignores `install/` and `state/`, which is exactly what a serving boot rewrites.

## Caveats

- **Tuning is per card.** Presets tuned on one GPU family are not automatically right for
  another. Promote a snapshot per instance type you serve, or boot once with
  `RETUNE = "1"` in `extra_env` when you move families.
- `enable_fsr` costs money per enabled availability zone for as long as it is on. It
  defaults to `false` here precisely because this module is often used to make an artefact
  that sits idle; the AZ defaults to the source volume's zone when you do enable it.
- Destroying this module deletes the snapshot. If a promoted snapshot has become the one
  you rely on, `terraform state rm` it rather than destroying it.
