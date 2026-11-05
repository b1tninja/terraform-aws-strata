# ─── strata-instance module ────────────────────────────────────────────────────
# Deploys a Strata inference instance from a pre-baked AMI + optional weights snapshot.
# This module can be used standalone (just the compute) or via the root module.

variable "name_prefix" {
  type    = string
  default = "strata"
}

variable "ami_id" {
  description = "Pre-baked AMI with Strata + Docker + drivers"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type (g6e.8xlarge, g6e.12xlarge, g5.24xlarge, etc.)"
  type        = string
  default     = "g6e.8xlarge"
}

variable "subnet_id" {
  description = "Subnet to launch in"
  type        = string
}

variable "security_group_ids" {
  description = "Security group IDs to attach"
  type        = list(string)
}

variable "iam_instance_profile_arn" {
  description = "IAM instance profile ARN"
  type        = string
  default     = null
}

variable "key_pair_name" {
  type    = string
  default = ""
}

variable "weights_snapshot_id" {
  description = "EBS snapshot with model weights (optional)"
  type        = string
  default     = ""
}

variable "data_volume_size" {
  type    = number
  default = 250
}

variable "data_volume_iops" {
  type    = number
  default = 16000
}

variable "data_volume_throughput" {
  type    = number
  default = 1000
}

variable "model" {
  type    = string
  default = "IQ3_XXS"
}

variable "model_family" {
  type    = string
  default = "qwen"
}

variable "api_key" {
  type      = string
  default   = ""
  sensitive = true
}

variable "strata_image_tag" {
  type    = string
  default = "latest-cuda13"
}

variable "context_length" {
  type    = string
  default = "128k"
}

variable "kv_quantization" {
  type    = string
  default = "int8"
}

variable "vision_mode" {
  type    = string
  default = "off"
}

variable "use_spot" {
  type    = bool
  default = false
}

variable "spot_max_price" {
  type    = string
  default = ""
}

variable "associate_public_ip" {
  type    = bool
  default = true
}

variable "ttl_minutes" {
  type    = number
  default = 0
}

variable "health_check_timeout" {
  type    = number
  default = 600
}

variable "extra_env" {
  type    = map(string)
  default = {}
}

variable "tune_mode" {
  description = "How the container tunes the run settings: quick, thorough or skip. The module asks for quick on first boot; the container's own default is skip."
  type        = string
  default     = "quick"
}

variable "parallel" {
  description = "Requests answered at the same time, 1 to 8; null lets the container fit it to the card."
  type        = number
  default     = null
}

variable "gpus" {
  description = "Cards the engine may use, e.g. \"0,1\"; empty means the engine's choice. Setting it can make the container regenerate the saved run settings, and it is mutually exclusive with gpu_roles."
  type        = string
  default     = ""
}

variable "gpu_roles" {
  description = "A role per card, e.g. \"1=main,0=helper\"; preferred over gpus on multi-card instances because it does not force the run settings to be rewritten. Mutually exclusive with gpus."
  type        = string
  default     = ""
}

variable "verify_weights" {
  description = "How carefully the boot checks the weights volume against the seeded manifest: off, sizes (default, one stat per file) or full (re-hash everything, minutes). Volumes with no manifest are reported and booted anyway."
  type        = string
  default     = "sizes"
}

variable "boot_hooks" {
  description = "Shell fragments to splice into the boot script after the model is healthy; see the root module's variable of the same name for the contract hooks rely on."
  type        = list(string)
  default     = []
}

variable "pre_start_hooks" {
  description = "Shell fragments to splice into the boot script before the container starts; see the root module's variable of the same name for the narrower contract these hooks run under."
  type        = list(string)
  default     = []
}

variable "tags" {
  type    = map(string)
  default = {}
}

# ─── User Data ─────────────────────────────────────────────────────────────────

locals {
  resolved_api_key = var.api_key != "" ? var.api_key : "strata-${substr(md5(var.model), 0, 16)}"

  user_data = replace(templatefile("${path.module}/../strata-ami/user_data/boot.sh.tpl", {
    model_family         = var.model_family
    model                = var.model
    api_key              = local.resolved_api_key
    use_secrets_manager  = false
    secret_id            = ""
    context_length       = var.context_length
    kv_quantization      = var.kv_quantization
    vision_mode          = var.vision_mode
    strata_image_tag     = var.strata_image_tag
    data_volume_device   = "/dev/nvme1n1"
    data_volume_mount    = "/data"
    port                 = 8080
    extra_env            = var.extra_env
    tune_mode            = var.tune_mode
    parallel             = var.parallel
    gpus                 = var.gpus
    gpu_roles            = var.gpu_roles
    verify_weights       = var.verify_weights
    health_check_timeout = var.health_check_timeout
    ttl_minutes          = var.ttl_minutes
    region               = "us-east-1"
    boot_hooks           = var.boot_hooks
    pre_start_hooks      = var.pre_start_hooks
  }), "\r\n", "\n")

  common_tags = merge(var.tags, {
    Project     = "strata-terraform"
    StrataModel = var.model
  })
}

# ─── Instance ──────────────────────────────────────────────────────────────────

resource "aws_instance" "this" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  key_name               = var.key_pair_name != "" ? var.key_pair_name : null
  vpc_security_group_ids = var.security_group_ids
  iam_instance_profile   = var.iam_instance_profile_arn != null ? replace(var.iam_instance_profile_arn, "/.*\\/(.*)/", "$1") : null

  associate_public_ip_address = var.associate_public_ip
  user_data                   = local.user_data

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    iops        = 3000
    encrypted   = true
  }

  dynamic "instance_market_options" {
    for_each = var.use_spot ? [1] : []
    content {
      market_type = "spot"
      spot_options {
        max_price                      = var.spot_max_price != "" ? var.spot_max_price : null
        instance_interruption_behavior = "terminate"
      }
    }
  }

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-instance" })
}

# ─── Data Volume (attached) ────────────────────────────────────────────────────

resource "aws_ebs_volume" "data" {
  count             = var.weights_snapshot_id != "" ? 1 : 0
  availability_zone = aws_instance.this.availability_zone
  size              = var.data_volume_size
  type              = "gp3"
  iops              = var.data_volume_iops
  throughput        = var.data_volume_throughput
  snapshot_id       = var.weights_snapshot_id
  encrypted         = true

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-data" })
}

resource "aws_volume_attachment" "data" {
  count                          = var.weights_snapshot_id != "" ? 1 : 0
  device_name                    = "/dev/sdb"
  volume_id                      = aws_ebs_volume.data[0].id
  instance_id                    = aws_instance.this.id
  stop_instance_before_detaching = true
}

# ─── Outputs ───────────────────────────────────────────────────────────────────

output "instance_id" {
  value = aws_instance.this.id
}

output "public_ip" {
  value = aws_instance.this.public_ip
}

output "private_ip" {
  value = aws_instance.this.private_ip
}

output "api_endpoint" {
  value = "http://${aws_instance.this.public_ip}:8080"
}
