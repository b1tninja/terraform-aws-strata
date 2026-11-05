# strata-instance-store

Serves the model pack from the instance's local NVMe instead of the EBS data volume, as a
**pre-start boot hook**. Off by default, and opt-in per deployment.

## When it is worth anything

An instance in the `g7e`, `g6e`, `g5` or `g7` families ships local NVMe, and the numbers are not
close: `g7e.8xlarge` has 1,900 GiB of it, rated **275,000 read / 137,500 write IOPS**, included in
the hourly price (Vantage instance data, 2026-11-05). The data volume is gp3, which *includes*
3,000 IOPS and 125 MiB/s - anything above that baseline is provisioned and billed by the month
against a volume that lives for an hour. (That type's EBS path tops out at 16,000 Mbps and
64,000 IOPS, which is exactly where gp3's own ceiling sits, so the instance is not what limits a
single volume here.)

That gap only matters for packs that read from SSD while serving. Most packs in the catalog
keep every expert resident in RAM and touch the disk only at load; for those, local NVMe buys
the boot a few minutes at most. The catalog marks the ones that spill as `budget` packs, and
`strata-catalog` already warns when instance RAM is below what the pack wants - that warning
is the signal to enable this.

## How to wire it

```hcl
module "scratch" {
  source = "./modules/strata-instance-store" # or the registry address once published

  enabled     = true
  scratch_gib = 1900 # instance store on g7e.8xlarge
  weights_gib = 128 # the pack being served
}

module "strata" {
  source          = "../../"
  pre_start_hooks = module.scratch.pre_start_hooks
}
```

If you instantiate `strata-catalog` yourself, `instance_entry.reference.nvme_gib` and
`model_entry.download_gb` are the two numbers to pass. The catalog records that figure for each
family's *reference* instance, and leaves it `null` where it is unknown (p5); a null arrives
here as "not told", which disables the plan-time check but not the runtime one - the hook
measures free space before copying and declines if it is short.

## What it does at boot

Runs in the pre-start phase: the data volume is mounted and its manifest verified, the
container has not started. It finds an instance-store disk by the model string the kernel
reports (`Amazon EC2 NVMe Instance Storage`), formats it once with the label
`strata-scratch`, copies the pack with `tar | tar`, verifies the copy's file sizes against the
volume's manifest, then bind-mounts the scratch tree over `/data` - with `install/`, `state/`
and `.strata-manifest/` bind-mounted back from the EBS volume.

Keeping the mutable paths on the volume matters: those are the run settings and tuning presets
that `strata-volume-snapshot` promotes, and the weights manifest deliberately ignores them. If
they moved to instance store they would be lost on terminate and the promotion lever would
stop working.

## It declines rather than fails

The whole hook runs in a subshell with errexit relaxed and ends `true`. It gives up and leaves
the boot on the EBS volume when there is no free instance-store disk, when the disk is too
small for the pack plus `min_free_gib`, when `tar` reports a short write, or when the verified
copy does not match the manifest. Each of those prints a line naming the reason, and the boot
continues. A plan-time guard in this module catches the size case earlier, where it is free:

```
instance-store: the pack plus 40 GiB headroom needs 540 GiB and this instance
advertises 100 GiB. Choose a larger instance, a smaller pack, or set
on_insufficient = "skip" to let the runtime decide.
```

Set `on_insufficient = "skip"` to make that a runtime decision instead of a plan error.

## Not yet measured

Nothing here has run on a real instance, so the two load-bearing assumptions are unverified:

- **Copy time.** Reading 128 GB off gp3 and writing it to local NVMe is expected to take a few
  minutes, which is cheap against an hour of a GPU instance but is not free, and the boot log
  prints the elapsed time precisely so it can be measured rather than believed.
- **Mount propagation.** The container sees the bind mounts only because the Docker daemon
  shares the host mount namespace, which is the default since 18.09. A unit that sets
  `MountFlags` would hide them, and the boot would look healthy while serving the EBS copy -
  not wrong, just silently not the thing asked for.

`tests/instance_store` asserts the hook's shape: that it never calls `wait_loaded()`, never
redefines `$DATA_MOUNT` or `$DATA_DEVICE`, identifies the disk by model string rather than
device name, verifies the copy before remapping `/data`, excludes and re-binds the mutable
paths, and checks `tar`'s exit status. The plan-time fit guard is asserted by a config whose
`terraform plan` is expected to fail.
