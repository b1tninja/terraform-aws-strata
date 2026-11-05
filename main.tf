# ─── Data Sources ──────────────────────────────────────────────────────────────

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# There used to be a `data "aws_vpc" "selected"` here, gated on var.vpc_id != "". Nothing read it:
# every consumer resolves the VPC through local.effective_vpc_id below, which uses var.vpc_id
# directly and only asks for the default VPC when it is empty. A data source nobody reads still
# costs a live DescribeVpcs call on every plan - and a IAM permission the module does not need.
data "aws_vpc" "default" {
  count   = var.vpc_id == "" ? 1 : 0
  default = true
}

data "aws_subnets" "selected" {
  filter {
    name   = "vpc-id"
    values = [var.vpc_id != "" ? var.vpc_id : data.aws_vpc.default[0].id]
  }
}

data "aws_subnet" "selected" {
  count = var.subnet_id != "" ? 1 : 0
  id    = var.subnet_id
}

locals {
  effective_vpc_id = var.vpc_id != "" ? var.vpc_id : data.aws_vpc.default[0].id

  effective_subnet_id = var.subnet_id != "" ? var.subnet_id : (
    length(data.aws_subnets.selected.ids) > 0 ? data.aws_subnets.selected.ids[0] : null
  )

  availability_zone = var.subnet_id != "" ? data.aws_subnet.selected[0].availability_zone : "us-east-1a"

  common_tags = merge(var.tags, {
    Project     = "strata-terraform"
    ManagedBy   = "terraform"
    StrataModel = var.model
  })

  # Stable across plans: random_password is stored in state, so the key no longer
  # rotates on every plan (timestamp() used to churn it, and the schedule with it).
  api_key = var.api_key != "" ? var.api_key : random_password.api_key[0].result
}

# ─── API Key Generation ────────────────────────────────────────────────────────

resource "random_password" "api_key" {
  count   = var.api_key == "" ? 1 : 0
  length  = 32
  special = false
}

# ─── Catalog (model sizes, instance support, volume sizing) ─────────────────────

module "catalog" {
  source = "./modules/strata-catalog"

  model         = var.model
  model_family  = var.model_family
  instance_type = var.instance_type
}

locals {
  # An explicit data_volume_size always wins; otherwise it comes from the model.
  data_volume_size = coalesce(var.data_volume_size, try(module.catalog.recommended_volume_gib, null), 250)
}

# ─── AMI Data Source (Deep Learning Base OSS AMI as fallback) ──────────────────

data "aws_ami" "dlami" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 24.04)*"]
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

# ─── Security Group ────────────────────────────────────────────────────────────

resource "aws_security_group" "strata" {
  name_prefix = "${var.name_prefix}-sg-"
  vpc_id      = local.effective_vpc_id
  description = "Strata inference server access"
  tags        = merge(local.common_tags, { Name = "${var.name_prefix}-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group_rule" "ingress_api" {
  type              = "ingress"
  from_port         = 8080
  to_port           = 8080
  protocol          = "tcp"
  cidr_blocks       = var.allowed_cidr_blocks
  security_group_id = aws_security_group.strata.id
  description       = "Strata API"
}

resource "aws_security_group_rule" "ingress_ssh" {
  count             = var.key_pair_name != "" ? 1 : 0
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = var.allowed_cidr_blocks
  security_group_id = aws_security_group.strata.id
  description       = "SSH"
}

resource "aws_security_group_rule" "egress_all" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.strata.id
  description       = "Allow all outbound"
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

resource "aws_iam_role" "strata_instance" {
  name               = "${var.name_prefix}-instance-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy" "strata_instance" {
  name = "${var.name_prefix}-instance-policy"
  role = aws_iam_role.strata_instance.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData", "logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "strata" {
  name = "${var.name_prefix}-instance-profile"
  role = aws_iam_role.strata_instance.name
  tags = local.common_tags
}

# ─── User Data (cloud-init) ───────────────────────────────────────────────────

locals {
  # CRLF-safe: a Windows working tree checks the template out with CR+LF, and a
  # "#!/bin/bash\r" shebang would stop cloud-init from executing the script.
  user_data = replace(templatefile("${path.module}/modules/strata-ami/user_data/boot.sh.tpl", {
    model_family         = var.model_family
    model                = var.model
    api_key              = var.use_secrets_manager ? "" : local.api_key
    use_secrets_manager  = var.use_secrets_manager
    secret_id            = local.api_key_secret_id
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
    health_check_timeout = var.health_check_timeout_seconds
    ttl_minutes          = var.ttl_minutes
    region               = data.aws_region.current.region
    min_driver_version   = var.min_driver_version
    boot_hooks           = var.boot_hooks
    pre_start_hooks      = var.pre_start_hooks
  }), "\r\n", "\n")
}

# ─── Launch Template ───────────────────────────────────────────────────────────

resource "aws_launch_template" "strata" {
  name_prefix   = "${var.name_prefix}-lt-"
  image_id      = var.ami_id != "" ? var.ami_id : data.aws_ami.dlami.id
  instance_type = var.instance_type
  key_name      = var.key_pair_name != "" ? var.key_pair_name : null

  vpc_security_group_ids = [aws_security_group.strata.id]
  iam_instance_profile {
    arn = aws_iam_instance_profile.strata.arn
  }

  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size           = 30
      volume_type           = "gp3"
      iops                  = 3000
      throughput            = 125
      delete_on_termination = true
      encrypted             = true
    }
  }

  # Data volume — from FSR snapshot if available (separate snapshot approach)
  dynamic "block_device_mappings" {
    for_each = var.weights_snapshot_id != "" ? [1] : []
    content {
      device_name = "/dev/sdb"
      ebs {
        snapshot_id           = var.weights_snapshot_id
        volume_size           = local.data_volume_size
        volume_type           = "gp3"
        iops                  = var.provisioned_iops
        throughput            = var.provisioned_throughput
        delete_on_termination = true
        encrypted             = true
      }
    }
  }

  # Bundled AMI mode: the data volume comes from the AMI's own BDM.
  # We override IOPS/throughput but don't specify a snapshot_id —
  # it inherits from the AMI. Set volume_size to match the AMI's mapping.
  dynamic "block_device_mappings" {
    for_each = var.use_bundled_ami && var.weights_snapshot_id == "" ? [1] : []
    content {
      device_name = var.bundled_data_volume_device
      ebs {
        volume_size           = local.data_volume_size
        volume_type           = "gp3"
        iops                  = var.provisioned_iops
        throughput            = var.provisioned_throughput
        delete_on_termination = true
        encrypted             = true
        # No snapshot_id — inherited from AMI BDM
      }
    }
  }

  # Data volume — empty, model downloads on first boot
  dynamic "block_device_mappings" {
    for_each = var.weights_snapshot_id == "" && !var.use_bundled_ami ? [1] : []
    content {
      device_name = "/dev/sdb"
      ebs {
        volume_size           = local.data_volume_size
        volume_type           = "gp3"
        iops                  = var.provisioned_iops
        throughput            = var.provisioned_throughput
        delete_on_termination = true
        encrypted             = true
      }
    }
  }

  user_data = base64encode(local.user_data)

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(local.common_tags, { Name = "${var.name_prefix}-instance" })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge(local.common_tags, { Name = "${var.name_prefix}-volume" })
  }

  tags = local.common_tags
}

# ─── On-Demand Instance ────────────────────────────────────────────────────────

resource "aws_instance" "strata" {
  count = var.use_spot ? 0 : 1

  launch_template {
    id      = aws_launch_template.strata.id
    version = "$Latest"
  }

  subnet_id                   = local.effective_subnet_id
  associate_public_ip_address = var.associate_public_ip

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-instance" })
}

# ─── Spot Instance ─────────────────────────────────────────────────────────────

resource "aws_instance" "strata_spot" {
  count = var.use_spot ? 1 : 0

  launch_template {
    id      = aws_launch_template.strata.id
    version = "$Latest"
  }

  subnet_id                   = local.effective_subnet_id
  associate_public_ip_address = var.associate_public_ip

  instance_market_options {
    market_type = "spot"
    spot_options {
      max_price                      = var.spot_max_price != "" ? var.spot_max_price : null
      instance_interruption_behavior = "terminate"
    }
  }

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-spot" })
}

# ─── EBS Fast Snapshot Restore ─────────────────────────────────────────────────

resource "aws_ebs_fast_snapshot_restore" "weights" {
  for_each = var.enable_fast_snapshot_restore && var.weights_snapshot_id != "" ? toset([local.availability_zone]) : toset([])

  snapshot_id       = var.weights_snapshot_id
  availability_zone = each.value
}
