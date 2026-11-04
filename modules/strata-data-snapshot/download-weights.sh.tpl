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

# Sync to disk
sync
df -h "$DATA_DIR"
du -sh "$DATA_DIR"/* 2>/dev/null || true

# Write completion marker
echo "COMPLETE: $(date -u +%Y-%m-%dT%H:%M:%SZ) MODEL=$MODEL FAMILY=$FAMILY" > /var/lib/strata-download-complete
echo "Download complete. Volume is ready for snapshot."

# Unmount cleanly so the snapshot is consistent
umount "$DATA_DIR"
