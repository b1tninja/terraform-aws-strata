# ─── strata-ami-bundled module ─────────────────────────────────────────────────
# Creates a multi-volume AMI where BOTH the software (Docker + Strata image) AND
# the model weights live inside the AMI's block device mapping.
#
# KEY INSIGHT: EBS snapshots are INCREMENTAL and block-level deduplicated.
# When you rebuild the AMI (new OS patches, new Docker image), the 250GB of
# unchanged weights in the data volume produce a new snapshot that references
# the same underlying S3 blocks. Cost: ~$0 extra for the unchanged data.
#
# AMIs are REGION-scoped and automatically available from all AZs.
# EBS snapshots are replicated across all AZs (stored in regional S3).
# The only per-AZ operation needed is enabling Fast Snapshot Restore - and note that this module
# does NOT do it. FSR is implemented in modules/strata-data-snapshot (aws_ebs_fast_snapshot_restore
# over the weights snapshot); the variables below are accepted here for interface parity with that
# module and currently change nothing. An earlier version of this comment claimed step 4 enabled
# FSR, which was not true of the code.
#
# Lifecycle:
#   1. Launch staging instance from this module
#   2. It installs Docker + Strata image + downloads model weights
#   3. Take an AMI from it (aws_ec2_ami creates incremental snapshots)
#   4. Enable FSR - NOT done here; use modules/strata-data-snapshot for the data snapshot
#   5. Destroy staging instance
#   6. Launch ephemeral production instances from the AMI
#   7. To update: re-run the staging flow → new AMI (incremental, fast)

variable "name_prefix" {
  description = "Resource name prefix"
  type        = string
  default     = "strata-ami"
}

# tflint-ignore: terraform_unused_declarations
variable "region" {
  description = "Accepted for parity with modules/strata-data-snapshot. Inert: a module cannot set the region, which comes from the caller's provider block or AWS_REGION."
  type        = string
  default     = "us-east-1"
}

# tflint-ignore: terraform_unused_declarations
variable "availability_zones" {
  description = "Accepted for parity with modules/strata-data-snapshot. Inert HERE: this module creates no per-AZ resource. Fast Snapshot Restore is configured in modules/strata-data-snapshot, where the same variable drives aws_ebs_fast_snapshot_restore."
  type        = list(string)
  default     = ["us-east-1a"]
}

variable "subnet_id" {
  description = "Subnet for the staging instance"
  type        = string
}

variable "base_ami_owners" {
  type    = list(string)
  default = ["amazon"]
}

variable "base_ami_name_pattern" {
  type    = string
  default = "Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 24.04)*"
}

variable "staging_instance_type" {
  description = "GPU instance for staging (needed to pull + verify Docker image, but not to run model). CPU-only is fine if you skip model loading verification."
  type        = string
  default     = "g6e.xlarge"
}

variable "data_volume_size" {
  description = "Size of the data volume in GiB (must fit model weights)"
  type        = number
  default     = 280
}

variable "model" {
  description = "Model to pre-download into the data volume"
  type        = string
}

variable "model_family" {
  type    = string
  default = "qwen"
}

variable "strata_image_tag" {
  description = "Image tag baked into the bundled AMI. Pinned by default; see the root module's variable of the same name for why moving tags are avoided."
  type        = string
  default     = "0.2.9-cuda13"
}

# tflint-ignore: terraform_unused_declarations
variable "enable_fsr" {
  description = "Accepted for parity with modules/strata-data-snapshot. Inert HERE: nothing in this module creates a snapshot to restore quickly - aws_ebs_fast_snapshot_restore lives in modules/strata-data-snapshot. Kept so a caller written against either module does not fail on an unknown variable; set the real one there."
  type        = bool
  default     = true
}

variable "key_pair_name" {
  type    = string
  default = ""
}

variable "tags" {
  type    = map(string)
  default = {}
}

# ─── Data: find base AMI ───────────────────────────────────────────────────────

data "aws_ami" "base" {
  most_recent = true
  owners      = var.base_ami_owners

  filter {
    name   = "name"
    values = [var.base_ami_name_pattern]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_subnet" "target" {
  id = var.subnet_id
}

# ─── Local ─────────────────────────────────────────────────────────────────────

locals {
  common_tags = merge(var.tags, {
    Project   = "strata-terraform"
    Role      = "staging-ami-build"
    Model     = var.model
    ManagedBy = "terraform"
  })

  user_data = templatefile("${path.module}/scripts/staging-provision.sh.tpl", {
    model            = var.model
    model_family     = var.model_family
    strata_image_tag = var.strata_image_tag
    data_device      = "/dev/sdf"
    data_mount       = "/data"
  })
}

# ─── Security Group (staging: outbound for downloads) ──────────────────────────

resource "aws_security_group" "staging" {
  name_prefix = "${var.name_prefix}-staging-"
  description = "Outbound for model/image downloads"
  vpc_id      = data.aws_subnet.target.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.common_tags
}

# ─── IAM ───────────────────────────────────────────────────────────────────────

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "staging" {
  name               = "${var.name_prefix}-staging-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  tags               = local.common_tags
}

resource "aws_iam_instance_profile" "staging" {
  name = "${var.name_prefix}-staging-profile"
  role = aws_iam_role.staging.name
}

# ─── Staging Instance (builds the AMI) ─────────────────────────────────────────

resource "aws_instance" "staging" {
  ami                    = data.aws_ami.base.id
  instance_type          = var.staging_instance_type
  subnet_id              = var.subnet_id
  key_name               = var.key_pair_name != "" ? var.key_pair_name : null
  vpc_security_group_ids = [aws_security_group.staging.id]
  iam_instance_profile   = aws_iam_instance_profile.staging.name

  user_data = local.user_data

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    volume_size = 40
    volume_type = "gp3"
    iops        = 3000
    throughput  = 125
    encrypted   = true
    tags        = merge(local.common_tags, { Role = "root" })
  }

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-staging" })

  instance_initiated_shutdown_behavior = "stop"
}

# ─── Data Volume (model weights, attached for AMI capture) ─────────────────────

resource "aws_ebs_volume" "data" {
  availability_zone = data.aws_subnet.target.availability_zone
  size              = var.data_volume_size
  type              = "gp3"
  iops              = 3000
  throughput        = 125
  encrypted         = true

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-data", Role = "weights" })
}

resource "aws_volume_attachment" "data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.staging.id

  stop_instance_before_detaching = true
}
