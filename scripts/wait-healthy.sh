#!/bin/bash
# Poll a Strata endpoint until the model is loaded and serving.
# Usage: ./wait-healthy.sh <endpoint_url> [timeout_seconds]
# Example: ./wait-healthy.sh http://54.1.2.3:8080 300

set -euo pipefail

ENDPOINT="${1:?Usage: $0 <endpoint_url> [timeout_seconds]}"
TIMEOUT="${2:-600}"

echo "Waiting for Strata at $ENDPOINT (timeout: ${TIMEOUT}s)..."
START=$(date +%s)

while true; do
  ELAPSED=$(( $(date +%s) - START ))
  if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
    echo "TIMEOUT after ${ELAPSED}s"
    exit 1
  fi

  if RESP=$(curl -sf "$ENDPOINT/health" 2>/dev/null); then
    LOADED=$(echo "$RESP" | jq -r '.loaded // false' 2>/dev/null || echo "false")
    if [ "$LOADED" = "true" ]; then
      echo "READY after ${ELAPSED}s"
      echo "$RESP" | jq .
      exit 0
    fi
  fi

  sleep 5
done
