#!/bin/bash
# Provisioning script for the AMI staging instance.
# This runs on first boot: installs Docker, pulls the Strata image, and
# downloads model weights onto the attached data volume.
# After this completes, the AMI is taken from the stopped instance.
set -euo pipefail

exec > >(tee /var/log/strata-staging.log) 2>&1
echo "=== AMI Staging Provisioning started at $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

MODEL="${model}"
FAMILY="${model_family}"
IMAGE_TAG="${strata_image_tag}"
VOL_DEVICE="${data_device}"
DATA_MOUNT="${data_mount}"

# ─── Wait for data volume to attach ───────────────────────────────────────────
echo "[1/4] Waiting for data volume $VOL_DEVICE ..."
for i in $(seq 1 60); do
  [ -b "$VOL_DEVICE" ] && break
  sleep 5
done
if [ ! -b "$VOL_DEVICE" ]; then
  echo "ERROR: $VOL_DEVICE not found"; exit 1
fi

# ─── Format and mount ─────────────────────────────────────────────────────────
mkfs.ext4 -L strata-weights "$VOL_DEVICE"
mkdir -p "$DATA_MOUNT"
mount "$VOL_DEVICE" "$DATA_MOUNT"
echo "$VOL_DEVICE $DATA_MOUNT ext4 defaults,noatime 0 2" >> /etc/fstab
echo "  Mounted $VOL_DEVICE at $DATA_MOUNT"

# ─── Install Docker + NVIDIA Container Toolkit ─────────────────────────────────
echo "[2/4] Installing runtime dependencies..."
if ! command -v docker &>/dev/null; then
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker
fi

if ! docker info 2>&1 | grep -qi "nvidia"; then
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
    gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
    tee /etc/apt/sources.list.d/nvidia-container-toolkit.list > /dev/null
  apt-get update -qq
  apt-get install -y -qq nvidia-container-toolkit
  nvidia-ctk runtime configure --runtime=docker
  systemctl restart docker
fi

# ─── Pull Strata Docker image ─────────────────────────────────────────────────
echo "[3/4] Pulling Strata image: ghcr.io/niko1221/strata:$IMAGE_TAG"
docker pull "ghcr.io/niko1221/strata:$IMAGE_TAG"

# ─── Download model weights ───────────────────────────────────────────────────
echo "[4/4] Downloading model $FAMILY/$MODEL into $DATA_MOUNT ..."
docker run --rm \
  -v "$DATA_MOUNT:/data" \
  -e "MODEL=$MODEL" \
  -e "FAMILY=$FAMILY" \
  -e "TUNE=skip" \
  --entrypoint /opt/strata/terminal/bin/strata \
  "ghcr.io/niko1221/strata:$IMAGE_TAG" \
  launch --no-tui --yes --no-start --model "$MODEL" --family "$FAMILY" \
  --data-dir /data 2>&1 || {
    echo "Primary download failed, trying setup.py..."
    docker run --rm \
      -v "$DATA_MOUNT:/data" \
      --entrypoint /opt/strata/terminal/python/bin/python3 \
      "ghcr.io/niko1221/strata:$IMAGE_TAG" \
      /opt/strata/terminal/setup.py --data-dir /data --model "$MODEL" --no-start
  }

# Verify weights exist
WEIGHT_COUNT=$(find "$DATA_MOUNT" -name "*.gguf" 2>/dev/null | wc -l)
echo "  Found $WEIGHT_COUNT .gguf files"
if [ "$WEIGHT_COUNT" -lt 1 ]; then
  echo "WARNING: No .gguf files found. Check model download."
fi

# ─── Cleanup and finalize ─────────────────────────────────────────────────────
sync
df -h "$DATA_MOUNT"
du -sh "$DATA_MOUNT"/* 2>/dev/null | sort -rh | head -10

# Remove any partial download artifacts, caches
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
docker system prune -f

echo "COMPLETE: $(date -u +%Y-%m-%dT%H:%M:%SZ)" > /var/lib/strata-staging-complete
echo "=== Staging provisioning done. Instance is ready for AMI creation. ==="

# Signal that we're done (shutdown the instance for clean snapshot)
sleep 10
poweroff
