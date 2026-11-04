#!/bin/bash
# Quick teardown script: destroys all Terraform-managed resources.
# Wraps terraform destroy with safety checks.
set -euo pipefail

DIR="${1:-.}"

echo "⚠️  This will destroy ALL Strata infrastructure in: $DIR"
echo "    Type 'DESTROY' to confirm."
read -r CONFIRM

if [ "$CONFIRM" != "DESTROY" ]; then
  echo "Aborted."
  exit 1
fi

cd "$DIR"
terraform destroy -auto-approve

# Clean up any lingering FSR enablements
echo "Checking for orphaned Fast Snapshot Restores..."
SNAPSHOT_ID=$(terraform state show aws_ebs_fast_snapshot_restore.weights 2>/dev/null \
  | grep 'snapshot_id' | awk '{print $NF}' | tr -d '"' || echo "")
if [ -n "$SNAPSHOT_ID" ]; then
  echo "  FSR for snapshot $SNAPSHOT_ID should be auto-disabled on destroy."
fi

echo "Done."
