# ─── strata-data-snapshot module ───────────────────────────────────────────────
# Manages the EBS volume snapshot containing pre-downloaded Strata model weights.
# Workflow: launches a staging instance → downloads model → snapshots volume → enables FSR.

variable "name_prefix" {
  description = "Resource name prefix"
  type        = string
  default     = "strata-weights"
}

# tflint-ignore: terraform_unused_declarations
variable "region" {
  description = "Inert, kept for interface stability: the region comes from the caller's provider block or AWS_REGION, never from a module input. The plan says so if it disagrees with the provider (check.region_matches_provider at the root module)."
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
  description = "Strata image tag (used to derive the download command). Pinned by default; see the root module's variable of the same name."
  type        = string
  default     = "0.2.9-cuda13"
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

  # CRLF-stripped: this becomes a staging instance's user_data verbatim, and "#!/bin/bash\r" is
  # a shebang cloud-init will not execute. The failure is quiet and expensive - the instance
  # never downloads, the volume is snapshotted empty, and that snapshot becomes the golden
  # reference every later instance restores from.
  user_data = replace(templatefile("${path.module}/download-weights.sh.tpl", {
    model         = var.model
    model_family  = var.model_family
    volume_device = "/dev/sdf"
    # The id, not the API device name, is what the script resolves the disk with: /dev/sdf is
    # what the attachment is told to use, which Nitro does not reproduce inside the instance.
    volume_id = aws_ebs_volume.staging.id
    # The download runs inside the engine image, so it has to honour the pin like everything else
    # does. This used to be hardcoded to latest-cuda13 in the template, which meant the weights
    # were always fetched by a moving build even when the caller pinned a version - and the
    # variable's own description claimed it derived this command.
    strata_image_tag = var.strata_image_tag
  }), "\r\n", "\n")

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

  # Ordering is enforced outside the resource graph: .github/workflows/refresh-weights.yml applies
  # the volume and instance first, waits for the download marker over SSM, then applies again so
  # this snapshot is created from a volume that actually holds the pack.
  #
  # There used to be ignore_changes = [volume_id] here, under a comment about waiting for the
  # instance to signal completion - which is not what that setting does. Its real effect was to
  # pin this snapshot to the volume id it first saw, so replacing the staging volume (a new size,
  # a new AZ, a refreshed pack) never re-snapshotted: the refresh workflow would re-download and
  # then publish the same stale snapshot id again, forever.

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
