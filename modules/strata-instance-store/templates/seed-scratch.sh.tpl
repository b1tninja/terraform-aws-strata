# ─── strata-instance-store: serve the pack from local NVMe ─────────────────────
# Opt-in layer rendered by modules/strata-instance-store. Best-effort by construction: every
# branch that cannot prove what it needs says so and leaves the boot serving from the EBS
# volume, because an optimisation that bricks a boot is worse than no optimisation.
#
# The reason to want it: a g7e.8xlarge ships 1900 GiB of instance-store NVMe rated in the
# hundreds of thousands of IOPS, and the data volume is gp3 at 16k unless provisioned higher.
# A "budget" pack that cannot keep every expert resident reads the remainder from SSD, so on
# those packs the SSD ceiling is part of the serving speed. The local disk is already paid for.
#
# What stays on EBS: ${mutable_list}. Run settings under install/ and tuning state under state/
# are written during normal operation, and the promotion step snapshots them. The scratch tree
# is bind-mounted over $DATA_MOUNT with those paths bind-mounted back from the volume, so the
# container still sees one tree and writes land where they always have.
#
# Two assumptions this repo has not measured on real hardware: copy throughput, and that the
# Docker daemon shares the host mount namespace. That has been the default since 18.09, but a
# unit setting MountFlags would hide these mounts from the container and the boot would still
# look healthy while serving the wrong bytes.
(
  set +e
  SCRATCH_MOUNT="${mount_point}"
  NEEDED_GIB=${weights_gib}
  MIN_FREE_GIB=${min_free_gib}
  MANIFEST="$DATA_MOUNT/.strata-manifest/files.txt"
  ok=1

  # Sizes, not digests: this runs on the boot path of every instance, and the failure worth
  # catching is a truncated copy, which is what a long read through a saturated link produces.
  # Full hashing stays available at boot through verify_weights = full.
  verify_copy() {
    local root="$1" manifest="$2" bad=0 n=0 path size actual
    if [ ! -f "$manifest" ]; then
      echo "  instance-store: no manifest on the volume, cannot verify a copy"
      return 1
    fi
    while read -r want size path; do
      if [ -z "$path" ]; then continue; fi
      if [ ! -f "$root/$path" ]; then
        echo "  instance-store: missing from scratch: $path"
        bad=$((bad + 1))
        continue
      fi
      actual=$(stat -c %s "$root/$path")
      if [ "$actual" != "$size" ]; then
        echo "  instance-store: wrong size in scratch: $path"
        bad=$((bad + 1))
      fi
      n=$((n + 1))
    done < "$manifest"
    echo "  instance-store: checked $n files, $bad problems"
    if [ "$bad" -eq 0 ] && [ "$n" -gt 0 ]; then return 0; fi
    return 1
  }

  # Instance storage reports its own model string, which is how it is told apart from root and
  # from the data volume without guessing device names - the same signal the mount step uses to
  # avoid the opposite mistake.
  scratch=""
  found=0
  for nd in /sys/class/nvme/nvme*; do
    if [ ! -e "$nd/device/model" ]; then continue; fi
    model=$(tr -d '[:space:]' < "$nd/device/model" 2>/dev/null)
    if [ "$model" = "AmazonEC2NVMeInstanceStorage" ]; then
      dev="/dev/$(basename "$nd")"
      if lsblk -rnpo NAME,PKNAME,MOUNTPOINT "$dev" 2>/dev/null | awk '$3 != ""' | grep -q .; then
        continue
      fi
      found=$((found + 1))
      if [ -z "$scratch" ]; then scratch="$dev"; fi
    fi
  done

  if [ -z "$scratch" ]; then
    echo "  instance-store: no free instance-store disk found; serving from the EBS volume."
    ok=0
  fi
  if [ "$found" -gt 1 ]; then
    echo "  instance-store: $found candidate disks; using the first ($scratch). Stripe them"
    echo "  yourself if you want the aggregate throughput."
  fi

  if [ "$ok" = "1" ]; then
    if blkid -L strata-scratch >/dev/null 2>&1; then
      scratch=$(blkid -L strata-scratch | head -n 1)
      mkdir -p "$SCRATCH_MOUNT"
      mountpoint -q "$SCRATCH_MOUNT" || mount "$scratch" "$SCRATCH_MOUNT"
      echo "  instance-store: reusing the filesystem already on $scratch"
    else
      mkfs.ext4 -q -F -L strata-scratch "$scratch"
      mkdir -p "$SCRATCH_MOUNT"
      mount "$scratch" "$SCRATCH_MOUNT"
      echo "  instance-store: formatted $scratch and mounted it at $SCRATCH_MOUNT"
    fi
    if ! mountpoint -q "$SCRATCH_MOUNT"; then
      echo "  instance-store: the mount did not take; serving from the EBS volume."
      ok=0
    fi
  fi

  if [ "$ok" = "1" ]; then
    avail=$(df --output=avail -BG "$SCRATCH_MOUNT" 2>/dev/null | tail -n 1 | tr -dc '0-9')
    if [ -z "$avail" ]; then avail=0; fi
    if [ "$avail" -lt "$((NEEDED_GIB + MIN_FREE_GIB))" ]; then
      echo "  instance-store: $avail GiB free, needs about $((NEEDED_GIB + MIN_FREE_GIB)) GiB"
      echo "  for the pack plus margin; serving from the EBS volume."
      umount "$SCRATCH_MOUNT"
      ok=0
    fi
  fi

  if [ "$ok" = "1" ]; then
    # A scratch disk survives a reboot - it is lost on stop or terminate - so the second boot of
    # the same instance can skip a copy that already verifies clean.
    if verify_copy "$SCRATCH_MOUNT" "$MANIFEST"; then
      echo "  instance-store: scratch already holds the pack; nothing to copy."
    else
      echo "  instance-store: copying the pack from $DATA_MOUNT; on a large model this takes minutes..."
      start=$(date +%s)
      tar -C "$DATA_MOUNT" ${tar_excludes} --exclude=./lost+found -cf - . | tar -C "$SCRATCH_MOUNT" -xf -
      copy_rc=$?
      echo "  instance-store: copy took $(( $(date +%s) - start )) s, tar exit $copy_rc"
      if [ "$copy_rc" -ne 0 ]; then
        echo "  instance-store: the copy reported failure; serving from the EBS volume."
        umount "$SCRATCH_MOUNT"
        ok=0
      elif ! verify_copy "$SCRATCH_MOUNT" "$MANIFEST"; then
        echo "  instance-store: the copy does not match the manifest; serving from the EBS volume."
        umount "$SCRATCH_MOUNT"
        ok=0
      fi
    fi
  fi

  if [ "$ok" = "1" ]; then
    # Mutable paths keep living on the EBS volume, then the scratch tree becomes /data. The
    # binds are made inside the scratch tree, so they travel with it when it is bind-mounted
    # over $DATA_MOUNT, and the container sees one directory at the path it already expects.
    for p in ${mutable_list}; do
      mkdir -p "$DATA_MOUNT/$p" "$SCRATCH_MOUNT/$p"
      mount --bind "$DATA_MOUNT/$p" "$SCRATCH_MOUNT/$p" || ok=0
    done
    if [ "$ok" = "1" ]; then
      mount --bind "$SCRATCH_MOUNT" "$DATA_MOUNT" || ok=0
    fi
    if [ "$ok" = "1" ]; then
      echo "  instance-store: /data now served from $scratch; ${mutable_list} still on the volume."
    else
      echo "  instance-store: the bind sequence did not complete; serving from the EBS volume."
      umount -R "$SCRATCH_MOUNT" 2>/dev/null
    fi
  fi

  [ "$ok" = "1" ]
) || echo "  instance-store: not used for this boot; nothing else changed."
true

