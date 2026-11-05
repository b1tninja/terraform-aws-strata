#!/bin/bash
# Runs on the staging instance: mounts the data volume, downloads model weights
# via Strata's setup, then writes a completion marker.
set -euo pipefail

exec > >(tee /var/log/strata-download.log) 2>&1
echo "=== Weights download started at $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

MODEL="${model}"
FAMILY="${model_family}"
VOL_DEVICE="${volume_device}"
VOL_ID="${volume_id}"
DATA_DIR="/mnt/strata-data"

# /dev/sdf is the name the attachment API was told to use, not necessarily the name this
# operating system uses. On Nitro an EBS volume appears as an NVMe device, and on an
# instance-store staging type the ephemeral disk can even claim a legacy name. Waiting for a
# name that never appears means this script fails after five minutes of polling; formatting a
# name that resolves to the wrong disk is worse, because whatever gets snapshotted here
# becomes the golden reference that every later instance restores from.
#
# The volume id is unambiguous and it is known at plan time, because this module creates the
# volume itself: Nitro exposes it as /dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_vol0...,
# Xen as /dev/disk/by-id/vol-... . The legacy name stays as a fallback, and is refused when
# the kernel reports it as instance storage.
resolve_volume() {
  local id_no_dash cand
  if [ -n "$VOL_ID" ]; then
    id_no_dash=$(printf '%s' "$VOL_ID" | tr -d '-')
    for cand in /dev/disk/by-id/*"$id_no_dash"*; do
      if [ -e "$cand" ]; then realpath -m "$cand"; return 0; fi
    done
  fi
  if [ -b "$VOL_DEVICE" ] && ! lsblk -dn -o NAME,MODEL "$VOL_DEVICE" 2>/dev/null | grep -qi 'instance storage'; then
    echo "$VOL_DEVICE"
    return 0
  fi
  return 1
}

RESOLVED_VOL=""
for i in $(seq 1 60); do
  if RESOLVED_VOL=$(resolve_volume); then break; fi
  sleep 5
done

if [ -z "$RESOLVED_VOL" ]; then
  echo "ERROR: volume $VOL_ID ($VOL_DEVICE) not found after 300s"
  echo "       Looked in /dev/disk/by-id for the volume id, then for $VOL_DEVICE."
  exit 1
fi
if [ "$RESOLVED_VOL" != "$VOL_DEVICE" ]; then
  echo "  Attachment name $VOL_DEVICE is $RESOLVED_VOL in this instance."
fi
VOL_DEVICE="$RESOLVED_VOL"

# Format and mount. Formatting is skipped when a filesystem is already there: a retried run
# must not destroy a volume that already holds a completed download, and this script has no
# way to tell its own earlier attempt apart from someone else's disk.
if blkid "$VOL_DEVICE" >/dev/null 2>&1; then
  echo "  $VOL_DEVICE already carries a filesystem; not formatting it."
else
  mkfs.ext4 -L strata-weights "$VOL_DEVICE"
fi
mkdir -p "$DATA_DIR"
mount "$VOL_DEVICE" "$DATA_DIR"

# Install Docker (staging AMI may not have it)
if ! command -v docker &>/dev/null; then
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker
fi

# Use the Strata container to download the model (no GPU needed for download).
# We run `strata launch --plan` equivalent: the setup.py inside the container
# fetches model files. We use `--no-start` to skip engine launch (no GPU).
echo "Downloading model: $FAMILY / $MODEL into $DATA_DIR ..."

# The Docker image has a download-only path via MODEL env + TUNE=skip + no GPU:
docker run --rm \
  -v "$DATA_DIR:/data" \
  -e "MODEL=$MODEL" \
  -e "FAMILY=$FAMILY" \
  -e "TUNE=skip" \
  --entrypoint /opt/strata/terminal/bin/strata \
  ghcr.io/niko1221/strata:${strata_image_tag} \
  launch --no-tui --yes --no-start --model "$MODEL" --family "$FAMILY" \
  --data-dir /data 2>&1 || true

# If the above doesn't support those flags (older versions), fallback:
# Use setup.py directly inside the container
if [ ! -d "$DATA_DIR/Strata-data" ] && [ ! -d "$DATA_DIR/models" ]; then
  echo "Primary download method failed, trying setup.py..."
  docker run --rm \
    -v "$DATA_DIR:/data" \
    --entrypoint /opt/strata/terminal/python/bin/python3 \
    ghcr.io/niko1221/strata:${strata_image_tag} \
    /opt/strata/terminal/setup.py --data-dir /data --model "$MODEL" --no-start
fi

# ─── Record what this volume now holds ───────────────────────────────────────────
# Strata's own installer checks every file against the SHA-256 it pins (docs/SAFETY.md:
# "Every model file has a fixed SHA-256 and size, and an install stops if the pinned
# version of a file is gone"), so the download is covered. What that check cannot cover is
# everything after it: the snapshot, every restore from it, and a volume that outlives
# dozens of instances. The manifest below is what a boot compares against, so a truncated
# or altered file is caught before an engine spends minutes loading it and then serves
# garbage from it.
#
# Format: "<sha256>  <bytes>  <path relative to the volume root>", sorted.
#
# Scope is the model data, and the exclusions are deliberate rather than tidy-ups:
#   state/     the API key and logs, which differ per instance
#   install/   the run settings, which are edited on purpose - tuning rewrites them, and a
#              boot hook records engine arguments there - so verifying them would fail
#              every boot after the first and teach people to set verify_weights = "off"
#   *.log      written as the instance runs
# A file that is legitimately rewritten must not be in a manifest that gates the boot.
MANIFEST_DIR="$DATA_DIR/.strata-manifest"
rm -rf "$MANIFEST_DIR"
mkdir -p "$MANIFEST_DIR"

echo "Writing the integrity manifest (one pass over the weights)..."
(
  cd "$DATA_DIR" || exit 1
  : > "$MANIFEST_DIR/files.txt"
  while IFS= read -r -d '' f; do
    digest=$(sha256sum "$f" | cut -d' ' -f1)
    size=$(stat -c %s "$f")
    printf '%s  %s  %s\n' "$digest" "$size" "$f" >> "$MANIFEST_DIR/files.txt"
  done < <(find . -type f \
    -not -path './.strata-manifest/*' \
    -not -path './state/*' \
    -not -path './install/*' \
    -not -name '*.log' \
    -print0 | sort -z)
)

MANIFEST_FILES=$(wc -l < "$MANIFEST_DIR/files.txt" | tr -d ' ')
MANIFEST_BYTES=$(awk '{ total += $2 } END { printf "%d", total }' "$MANIFEST_DIR/files.txt")
printf 'created=%s model=%s family=%s files=%s bytes=%s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$MODEL" "$FAMILY" "$MANIFEST_FILES" "$MANIFEST_BYTES" \
  > "$MANIFEST_DIR/manifest.info"
cat "$MANIFEST_DIR/manifest.info"

# Sync to disk
sync
df -h "$DATA_DIR"
du -sh "$DATA_DIR"/* 2>/dev/null || true

# Write completion marker
echo "COMPLETE: $(date -u +%Y-%m-%dT%H:%M:%SZ) MODEL=$MODEL FAMILY=$FAMILY" > /var/lib/strata-download-complete
echo "Download complete. Volume is ready for snapshot."

# Unmount cleanly so the snapshot is consistent
umount "$DATA_DIR"
