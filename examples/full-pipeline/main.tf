# Example: Full pipeline — build AMI + prepare weights snapshot + launch instance
# This is the most complete example, showing all three modules working together.
#
# In practice, the AMI and weights snapshot are built once (infrequent) and
# instances are launched/destroyed many times (frequent). This example shows both.

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.30.0"
    }
  }
}

provider "aws" {
  region = var.region
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "subnet_id" {
  description = "Subnet for all instances"
  type        = string
}

variable "model" {
  type    = string
  default = "IQ3_XXS"
}

variable "build_ami" {
  description = "Whether to build the AMI (set to false once you have a stable AMI)"
  type        = bool
  default     = false
}

variable "build_weights" {
  description = "Whether to build the weights snapshot (set to false once you have one)"
  type        = bool
  default     = false
}

variable "existing_ami_id" {
  description = "Pre-built AMI ID (used when build_ami = false)"
  type        = string
  default     = ""
}

variable "existing_snapshot_id" {
  description = "Pre-built weights snapshot ID (used when build_weights = false)"
  type        = string
  default     = ""
}

# ─── AMI Build (run once) ──────────────────────────────────────────────────────

module "ami" {
  source = "../../modules/strata-ami"
  count  = var.build_ami ? 1 : 0

  name_prefix         = "strata-prod"
  strata_image_tag    = "0.2.9-cuda13" # pinned: see the root module's variable for why
  build_instance_type = "g6e.xlarge"
  subnet_id           = var.subnet_id

  tags = { Environment = "production", Role = "ami-builder" }
}

# ─── Weights Snapshot (run once per model) ─────────────────────────────────────

module "weights" {
  source = "../../modules/strata-data-snapshot"
  count  = var.build_weights ? 1 : 0

  name_prefix           = "strata-weights-${var.model}"
  region                = var.region
  model                 = var.model
  model_family          = "qwen"
  volume_size           = 250
  availability_zones    = ["us-east-1a"]
  staging_instance_type = "c6i.xlarge"
  staging_subnet_id     = var.subnet_id
  enable_fsr            = true

  tags = { Environment = "production", Role = "weights-staging" }
}

# ─── Inference Instance (run many times) ───────────────────────────────────────

locals {
  # Use freshly built resources, or existing ones
  final_ami_id      = var.build_ami ? module.ami[0].ami_id : var.existing_ami_id
  final_snapshot_id = var.build_weights ? module.weights[0].snapshot_id : var.existing_snapshot_id
}

module "instance" {
  source = "../../modules/strata-instance"

  name_prefix         = "strata-serving"
  ami_id              = local.final_ami_id
  instance_type       = "g6e.8xlarge"
  subnet_id           = var.subnet_id
  security_group_ids  = [aws_security_group.serving.id]
  associate_public_ip = true

  weights_snapshot_id    = local.final_snapshot_id
  data_volume_size       = 250
  data_volume_iops       = 16000
  data_volume_throughput = 1000

  model        = var.model
  model_family = "qwen"
  ttl_minutes  = 60
  tags         = { Environment = "production", Role = "inference" }
}

resource "aws_security_group" "serving" {
  name_prefix = "strata-serving-"
  description = "Strata inference endpoint"
  vpc_id      = data.aws_subnet.target.vpc_id

  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

data "aws_subnet" "target" {
  id = var.subnet_id
}

output "endpoint" {
  value = module.instance.api_endpoint
}
