#!/bin/bash
# Runs on the staging instance: mounts the data volume, downloads model weights
# via Strata's setup, then writes a completion marker.
set -euo pipefail

exec > >(tee /var/log/strata-download.log) 2>&1
echo "=== Weights download started at $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

MODEL="${model}"
FAMILY="${model_family}"
VOL_DEVICE="${volume_device}"
DATA_DIR="/mnt/strata-data"

# Wait for volume to attach
for i in $(seq 1 60); do
  [ -b "$VOL_DEVICE" ] && break
  sleep 5
done

if [ ! -b "$VOL_DEVICE" ]; then
  echo "ERROR: Volume $VOL_DEVICE not found"
  exit 1
fi

# Format and mount
mkfs.ext4 -L strata-weights "$VOL_DEVICE"
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
  ghcr.io/niko1221/strata:latest-cuda13 \
  launch --no-tui --yes --no-start --model "$MODEL" --family "$FAMILY" \
  --data-dir /data 2>&1 || true

# If the above doesn't support those flags (older versions), fallback:
# Use setup.py directly inside the container
if [ ! -d "$DATA_DIR/Strata-data" ] && [ ! -d "$DATA_DIR/models" ]; then
  echo "Primary download method failed, trying setup.py..."
  docker run --rm \
    -v "$DATA_DIR:/data" \
    --entrypoint /opt/strata/terminal/python/bin/python3 \
    ghcr.io/niko1221/strata:latest-cuda13 \
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
