# ─── strata-data-snapshot module ───────────────────────────────────────────────
# Manages the EBS volume snapshot containing pre-downloaded Strata model weights.
# Workflow: launches a staging instance → downloads model → snapshots volume → enables FSR.

variable "name_prefix" {
  description = "Resource name prefix"
  type        = string
  default     = "strata-weights"
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "availability_zones" {
  description = "AZs to enable Fast Snapshot Restore in"
  type        = list(string)
  default     = ["us-east-1a"]
}

variable "model" {
  description = "Model identifier (e.g. IQ3_XXS, UD-Q6_K_XL)"
  type        = string
}

variable "model_family" {
  description = "Model family (qwen, deepseek41, coder)"
  type        = string
  default     = "qwen"
}

variable "volume_size" {
  description = "Size of the weights volume in GiB"
  type        = number
  default     = 250
}

variable "staging_instance_type" {
  description = "Instance type for the staging instance (CPU-only is fine for downloading)"
  type        = string
  default     = "c6i.xlarge"
}

variable "staging_subnet_id" {
  description = "Subnet for the staging instance"
  type        = string
  default     = ""
}

variable "staging_ami_id" {
  description = "AMI for the staging instance (Ubuntu 24.04)"
  type        = string
  default     = ""
}

variable "key_pair_name" {
  description = "Key pair for SSH access to staging instance"
  type        = string
  default     = ""
}

variable "use_spot" {
  description = <<-EOT
    Run the staging download on spot capacity. It is CPU and network work, so it discounts
    well - but a reclamation mid-download means the download runs again from the start,
    which costs hours rather than money. Worth it for a small pack or a patient iteration;
    leave it off for the one 128 GB run you actually need to finish.
  EOT
  type        = bool
  default     = false
}

variable "spot_max_price" {
  description = "Optional hourly price cap for the spot staging instance, as a string. Empty means no cap, which still gets interrupted when capacity runs out."
  type        = string
  default     = ""
}

variable "enable_fsr" {
  description = "Enable Fast Snapshot Restore on the resulting snapshot"
  type        = bool
  default     = true
}

variable "strata_image_tag" {
  description = "Strata image tag (used to derive the download command)"
  type        = string
  default     = "latest-cuda13"
}

variable "tags" {
  description = "Common tags"
  type        = map(string)
  default     = {}
}

# ─── Staging AMI ───────────────────────────────────────────────────────────────

data "aws_ami" "ubuntu" {
  count       = var.staging_ami_id == "" ? 1 : 0
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  staging_ami = var.staging_ami_id != "" ? var.staging_ami_id : data.aws_ami.ubuntu[0].id

  common_tags = merge(var.tags, {
    Project   = "strata-terraform"
    Role      = "weights-staging"
    Model     = var.model
    ManagedBy = "terraform"
  })
}

# ─── Staging Volume ────────────────────────────────────────────────────────────

resource "aws_ebs_volume" "staging" {
  availability_zone = var.availability_zones[0]
  size              = var.volume_size
  type              = "gp3"
  iops              = 3000
  throughput        = 125
  encrypted         = true

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-staging-vol" })
}

# ─── Staging Instance ──────────────────────────────────────────────────────────

resource "aws_instance" "staging" {
  ami                    = local.staging_ami
  instance_type          = var.staging_instance_type
  subnet_id              = var.staging_subnet_id
  key_name               = var.key_pair_name != "" ? var.key_pair_name : null
  vpc_security_group_ids = [aws_security_group.staging.id]

  # Spot is a real discount on a run that is mostly waiting on the network, with a catch
  # worth stating: the download is long, and a reclamation mid-way means starting it over,
  # because nothing resumes it. The data volume is a separate resource and survives, so the
  # re-run re-downloads into the same volume rather than losing storage.
  dynamic "instance_market_options" {
    for_each = var.use_spot ? [1] : []
    content {
      market_type = "spot"

      spot_options {
        spot_instance_type = "one-time"
        max_price          = var.spot_max_price != "" ? var.spot_max_price : null
      }
    }
  }

  user_data = templatefile("${path.module}/download-weights.sh.tpl", {
    model         = var.model
    model_family  = var.model_family
    volume_device = "/dev/sdf"
  })

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-staging" })

  # Instance terminates after download (lifecycle: create then snapshot then destroy)
  # Terraform manages the snapshot lifecycle
}

resource "aws_volume_attachment" "staging" {
  instance_id = aws_instance.staging.id
  volume_id   = aws_ebs_volume.staging.id
  device_name = "/dev/sdf"
}

# ─── Security Group (staging) ──────────────────────────────────────────────────

resource "aws_security_group" "staging" {
  name_prefix = "${var.name_prefix}-staging-"
  description = "Outbound-only for model downloads"
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = local.common_tags
}

# ─── Snapshot ──────────────────────────────────────────────────────────────────

resource "aws_ebs_snapshot" "weights" {
  volume_id = aws_ebs_volume.staging.id

  # Wait until the staging instance signals completion before snapshotting.
  # In practice, this is coordinated by the CI workflow calling terraform apply
  # in phases, or by a null_resource that polls SSM Run Command output.
  lifecycle {
    ignore_changes = [volume_id]
  }

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-${var.model}" })
}

# ─── Fast Snapshot Restore ─────────────────────────────────────────────────────

resource "aws_ebs_fast_snapshot_restore" "weights" {
  for_each = var.enable_fsr ? toset(var.availability_zones) : toset([])

  snapshot_id       = aws_ebs_snapshot.weights.id
  availability_zone = each.value
}

# ─── Outputs ───────────────────────────────────────────────────────────────────

output "snapshot_id" {
  description = "The EBS snapshot ID containing pre-downloaded model weights"
  value       = aws_ebs_snapshot.weights.id
}

output "volume_id" {
  description = "The staging volume ID (pre-snapshot)"
  value       = aws_ebs_volume.staging.id
}
