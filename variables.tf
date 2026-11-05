# ─── General ───────────────────────────────────────────────────────────────────
variable "name_prefix" {
  description = "Prefix for all resource names"
  type        = string
  default     = "strata"
}

variable "region" {
  description = "AWS region to deploy in"
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
  description = "Strata Docker image tag to pull (e.g. 'latest-cuda13', '0.2.7-cuda13')"
  type        = string
  default     = "latest-cuda13"
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
