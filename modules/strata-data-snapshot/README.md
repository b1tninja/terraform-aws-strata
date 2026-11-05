# strata-data-snapshot

Creates an EBS snapshot of a volume holding model weights: a temporary instance downloads
them (`download-weights.sh.tpl`), the volume is snapshotted, and the instance is torn
down. The snapshot ID is what `weights_snapshot_id` expects everywhere else, so the
download happens once instead of at every boot.

Pairs with `enable_fast_snapshot_restore` on the instance to cut restore time.
