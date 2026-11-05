# ─── Hook: control vector (refusal-direction projection) ────────────────────────
# Rendered by modules/strata-control-vector from upstream commit ${commit_ref}.
# Generated output: edit the module, not this text.
#
# Contract with the base boot script: runs as root after the model reports healthy,
# with $DATA_MOUNT and wait_loaded() in scope and set -euo pipefail active, so a failure
# here aborts the boot on purpose.
echo "=== hook: control vector (refusal-direction projection) ==="

command -v jq >/dev/null 2>&1 || {
  apt-get update -qq
  apt-get install -y -qq jq >/dev/null
}

CV_DIR="$DATA_MOUNT/control-vectors"
mkdir -p "$CV_DIR"

# Fetch unless already on the volume, and verify either way: a weights volume is
# long-lived, and a file that stopped matching its pin must not be used.
cv_fetch() {
  local name want
  name="$1"
  want="$2"
  if [ ! -f "$CV_DIR/$name" ]; then
    echo "  fetching $name"
    curl -fsSL --retry 5 --retry-delay 5 -o "$CV_DIR/$name.part" "${base}/$name"
    if ! printf '%s  %s.part\n' "$want" "$name" | (cd "$CV_DIR" && sha256sum --check --status -); then
      echo "ERROR: SHA-256 mismatch for $name - refusing to use it"
      rm -f "$CV_DIR/$name.part"
      exit 1
    fi
    mv "$CV_DIR/$name.part" "$CV_DIR/$name"
  elif ! printf '%s  %s\n' "$want" "$name" | (cd "$CV_DIR" && sha256sum --check --status -); then
    echo "ERROR: $name already on the volume does not match its pinned digest"
    exit 1
  fi
  echo "  $name verified"
}

%{ for name, digest in files ~}
cv_fetch "${name}" "${digest}"
%{ endfor ~}

# The engine runs as uid 10001 and only reads these, but the directory must be
# traversable and the files readable for it to do even that.
chmod -R a+rX "$CV_DIR"

CV_CONFIG=""
for candidate in "$DATA_MOUNT"/install/strata-*.json; do
  if [ -f "$candidate" ]; then CV_CONFIG="$candidate"; fi
done
if [ -z "$CV_CONFIG" ]; then
  echo "ERROR: no run config under $DATA_MOUNT/install for the vector to attach to"
  exit 1
fi

# user_args is the channel that survives the engine rewriting the rest of the file, and
# sampling.experimental_speed_projection is the default for requests that say nothing.
# The engine starts with the vector loaded; each request then chooses.
CV_TMP=$(mktemp)
jq --argjson ua '${args_json}' --argjson on ${default_on} \
  '.user_args = $ua | .sampling = (.sampling // {}) | .sampling.experimental_speed_projection = $on' \
  "$CV_CONFIG" >"$CV_TMP"
# cat, not mv: keeps the inode and permissions the container already holds open.
cat "$CV_TMP" >"$CV_CONFIG"
rm -f "$CV_TMP"
echo "  $CV_CONFIG loads the vector; projection default for requests: ${default_on}"
%{ if separate_endpoint ~}

# Making the steered configuration report its own name is for callers that route or
# gate on /v1/models; per-request selection does not need it.
CV_BASE=$(jq -r '.model_name // "strata"' "$CV_CONFIG")
case "$CV_BASE" in
  *${suffix}) CV_NAME="$CV_BASE" ;;
  *) CV_NAME="$CV_BASE${suffix}" ;;
esac
jq --arg name "$CV_NAME" '.model_name = $name' "$CV_CONFIG" >"$CV_TMP"
cat "$CV_TMP" >"$CV_CONFIG"
rm -f "$CV_TMP"
echo "  $CV_CONFIG now serves $CV_NAME"
%{ endif ~}

# Loading a vector happens when the engine starts, so it has to restart once. After
# this, both behaviours come from the same process and the same weights.
docker restart strata >/dev/null
wait_loaded || exit 1
echo "  projection loaded: choose per request with experimental_speed_projection"
