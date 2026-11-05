# ─── General ───────────────────────────────────────────────────────────────────
variable "name_prefix" {
  description = "Prefix for all resource names"
  type        = string
  default     = "strata"
}

variable "region" {
  description = <<-EOT
    The region this configuration is written down as targeting, e.g. "us-east-1". It does NOT
    select the region resources land in - a reusable module must not configure an AWS provider, so
    the region comes from the provider block in the caller's root module (or AWS_REGION). The
    default matches us-east-1 because that is where the catalogue's prices and the verified GPU
    availability were measured.

    If this value and the provider's actual region disagree, the plan says so: a module input named
    "region" that silently does nothing is the kind of thing that puts a stack in the wrong region.
  EOT
  type        = string
  default     = "us-east-1"
}

variable "tags" {
  description = "Common tags applied to all resources"
  type        = map(string)
  default     = {}
}

# ─── Networking ───────────────────────────────────────────────────────────────
variable "vpc_id" {
  description = "VPC ID to deploy into. Leave empty to use the default VPC."
  type        = string
  default     = ""
}

variable "subnet_id" {
  description = "Subnet ID for the instance. Leave empty to auto-select."
  type        = string
  default     = ""
}

variable "allowed_cidr_blocks" {
  description = "CIDR blocks allowed to access the Strata API port"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "associate_public_ip" {
  description = "Whether to associate a public IP address"
  type        = bool
  default     = true
}

# ─── Compute ──────────────────────────────────────────────────────────────────
variable "instance_type" {
  description = "EC2 instance type. See docs/MODELS.md for recommendations per model."
  type        = string
  default     = "g6e.8xlarge"
}

variable "use_spot" {
  description = "Use spot instances for cost savings (may be interrupted)"
  type        = bool
  default     = false
}

variable "spot_max_price" {
  description = "Maximum hourly price for spot instance. Empty = on-demand price."
  type        = string
  default     = ""
}

variable "key_pair_name" {
  description = "EC2 key pair name for SSH access (optional)"
  type        = string
  default     = ""
}

# ─── AMI / Image ──────────────────────────────────────────────────────────────
variable "ami_id" {
  description = "Pre-built AMI ID with Strata baked in. If empty, uses the latest Deep Learning AMI and installs on first boot."
  type        = string
  default     = ""
}

variable "strata_image_tag" {
  description = <<-EOT
    Strata Docker image tag to pull, pinned by default. Upstream publishes both moving tags
    (latest-cuda13) and pinned ones per backend: <version>-cuda12, -cuda13, -rocm-gfx110x,
    -rocm-gfx1151, -rocm-gfx120x, -sycl. List what exists with an anonymous token:
      curl -s "https://ghcr.io/token?scope=repository:niko1221/strata:pull&service=ghcr.io"
      curl -s -H "Authorization: Bearer <token>" https://ghcr.io/v2/niko1221/strata/tags/list

    Pinned because a moving tag lets two boots of an unchanged configuration run different engine
    builds, and the control-vector layer pins a commit and its engine arguments precisely because
    upstream's docs and shipped defaults have disagreed before. Note the images can lag the app
    release: Strata 0.2.10 was published as an app release before any 0.2.10 image tag appeared.
    Setting a latest-* tag here is allowed and produces a plan-time warning, not an error.
  EOT
  type        = string
  default     = "0.2.9-cuda13"

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9._-]*$", var.strata_image_tag))
    error_message = "strata_image_tag must be a single OCI tag with no slash or whitespace."
  }
}

# ─── Model / Data ─────────────────────────────────────────────────────────────
variable "model" {
  description = "Strata model identifier (e.g. IQ3_XXS, Q2_0, IQ2_XS, UD-Q6_K_XL, NVFP4). The catalog in modules/strata-catalog lists every accepted value and derives the volume size from it."
  type        = string
  default     = "IQ3_XXS"
}

variable "model_family" {
  description = "Model family: qwen, swift, coder, unsloth, gyro, nvfp4 or deepseek41"
  type        = string
  default     = "qwen"
}

variable "strict_catalog" {
  description = "Fail the plan when model or model_family is not in modules/strata-catalog. Turn it off to deploy a size the catalog has not been updated for yet."
  type        = bool
  default     = true
}

variable "weights_snapshot_id" {
  description = "EBS snapshot ID containing pre-downloaded model weights. If empty, model downloads on first boot (slow)."
  type        = string
  default     = ""
}

variable "data_volume_size" {
  description = "Size of the /data volume in GiB. When unset it is derived from the model's download size plus headroom (see modules/strata-catalog)."
  type        = number
  default     = null
}

variable "enable_fast_snapshot_restore" {
  description = "Enable EBS Fast Snapshot Restore on the weights volume for instant initialization"
  type        = bool
  default     = true
}

variable "provisioned_iops" {
  description = "EBS gp3 provisioned IOPS for the data volume"
  type        = number
  default     = 16000
}

variable "provisioned_throughput" {
  description = "EBS gp3 provisioned throughput in MiB/s for the data volume"
  type        = number
  default     = 1000
}

# ─── Strata Configuration ─────────────────────────────────────────────────────
variable "api_key" {
  description = "API key for the Strata server. Auto-generated if empty."
  type        = string
  default     = ""
  sensitive   = true
}

variable "context_length" {
  description = "Maximum context window (32k, 64k, 128k, 256k, or a number)"
  type        = string
  default     = "128k"
}

variable "kv_quantization" {
  description = "KV cache quantization (int8, q4_0, k8v4, fp16)"
  type        = string
  default     = "int8"
}

variable "vision_mode" {
  description = "Vision mode: off, on, gpu, cpu"
  type        = string
  default     = "off"
}

variable "extra_env" {
  description = "Additional environment variables to pass to the Strata container"
  type        = map(string)
  default     = {}
}

variable "tune_mode" {
  description = <<-EOT
    How the container tunes the run settings: "quick", "thorough" or "skip". Tuning
    happens once and is kept in the preset, so a restart does not tune again; set this to
    "skip" to leave whatever tuning the volume already has alone, or pass RETUNE=1 through
    extra_env to force a fresh pass.

    The container's own default is "skip"; this module asks for a quick pass on first boot
    because an untuned preset is measurably slower and there is nobody at the keyboard.
  EOT
  type        = string
  default     = "quick"
}

variable "parallel" {
  description = <<-EOT
    Requests answered at the same time, 1 to 8. Leave unset and the container fits it to
    the card, which is the right answer almost always: this is a routed model whose decode
    is bound by card bandwidth, so more concurrency mostly costs memory.
  EOT
  type        = number
  default     = null
}

variable "gpus" {
  description = <<-EOT
    Which cards the engine may use, as the monitor numbers them: "0" or "0,1". Empty means
    the engine's choice.

    Two things follow from setting it. On a volume whose model is already set up, the
    container deletes the saved run settings when they name a different card and lets setup
    write them again from the files present (docker/entrypoint.sh:206-216; the weights are
    kept). That also drops anything a boot hook recorded in the run config, which is why
    hooks re-apply on every boot rather than once. And it cannot be combined with
    gpu_roles, which the container treats as a hard error (:222).
  EOT
  type        = string
  default     = ""
}

variable "gpu_roles" {
  description = <<-EOT
    A role per card instead of a card list: "1=main,0=helper", roles being main, helper
    or off, and unnamed cards off. Mutually exclusive with gpus.

    Prefer this on multi-card instances: the roles are written into the run settings at
    every start, so nothing saved has to be dropped the way gpus does (docs/DOCKER.md:124,
    docker/entrypoint.sh:218-224).
  EOT
  type        = string
  default     = ""
}

variable "verify_weights" {
  description = <<-EOT
    How carefully the boot checks the weights volume against the manifest written when the
    snapshot was seeded: "off", "sizes" (default) or "full".

    "sizes" compares each recorded file size, which costs one stat per file and catches
    what actually goes wrong in practice - a truncated or missing file after a restore.
    "full" re-hashes every byte against the seeded SHA-256, which is minutes on a 128 GB
    pack: worth running once per snapshot, or when an instance behaves oddly, not on every
    boot. Either mode fails the boot rather than serving a model that is not whole.

    This covers storage after the install. The download itself is verified by Strata's own
    installer, which pins a SHA-256 and a size per file (see docs/SAFETY.md upstream), and
    a volume with no manifest - one prepared by hand, or an older snapshot - is reported
    and booted anyway, because there is nothing to compare it against.

    Scope is the model data. The run settings under install/ and everything under state/
    are excluded, because they are edited during normal operation - tuning rewrites them,
    and a boot hook records engine arguments there - so a manifest that watched them would
    fail every boot and only teach people to turn this off.
  EOT
  type        = string
  default     = "sizes"
}

variable "boot_hooks" {
  description = <<-EOT
    Shell fragments to splice into the boot script, in order, after the model reports
    healthy. This is the extension point: the core module deliberately knows nothing
    about what a hook does, so new serving behaviour arrives as a module rather than as
    another input here. They are called hooks rather than layers because a control
    vector already owns the word "layer" in this project.

    Contract offered to a hook: it runs as root with $DATA_MOUNT, $DATA_DEVICE, $MODEL,
    $MODEL_FAMILY, $PORT, $REGION, $HEALTH_TIMEOUT and wait_loaded() in scope, and with
    set -euo pipefail active, so a failing hook aborts the boot. A hook is opaque text
    and Terraform cannot check it against the script, so tests/boot_hooks asserts the
    contract for whatever ships in this repository.

    The shipped hook loads a control vector so one model serves two behaviours:
      boot_hooks = [module.steer.boot_hook]   # see modules/strata-control-vector
  EOT
  type        = list(string)
  default     = []
}

variable "min_driver_version" {
  description = <<-EOT
    Extra floor for the boot-time driver check, e.g. "580.126.04". Empty (the default) does NOT
    mean unchecked: the boot already derives a floor from the image tag using NVIDIA's published
    compatibility table - CUDA 13.x needs driver >= 580, CUDA 12.x needs >= 525 - and refuses to
    start the container below it. Set this only to raise the requirement further; a value below
    the tag's own floor is ignored, because that floor is not a preference.

    The reason this is enforced at boot rather than at plan: a driver older than the image's CUDA
    build produces no plan-time error. The container starts, the engine reports an insufficient
    driver version, and the instance bills while it does.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.min_driver_version == "" || can(regex("^[0-9]+(\\.[0-9]+){0,2}$", var.min_driver_version))
    error_message = "min_driver_version must be empty or a dotted numeric version such as 580.65.06."
  }
}

variable "pre_start_hooks" {
  description = <<-EOT
    Shell fragments spliced into the boot script before the container starts, for layers that
    change what /data points at rather than how the model serves - a weights copy on local
    NVMe, say. The contract is narrower than boot_hooks: wait_loaded() does not exist yet
    because nothing is serving, and set -euo pipefail is active, so a hook that fails aborts
    the boot. An optimisation hook should therefore run its body in a subshell that relaxes
    errexit and ends true; modules/strata-instance-store does exactly that.

      pre_start_hooks = [module.scratch.pre_start_hook]   # see modules/strata-instance-store
  EOT
  type        = list(string)
  default     = []
}

# ─── Lifecycle ────────────────────────────────────────────────────────────────
variable "ttl_minutes" {
  description = "Auto-terminate the instance after this many minutes (0 = no auto-terminate)"
  type        = number
  default     = 0
}

variable "health_check_timeout_seconds" {
  description = "Max seconds to wait for the model to finish loading before giving up"
  type        = number
  default     = 600
}
