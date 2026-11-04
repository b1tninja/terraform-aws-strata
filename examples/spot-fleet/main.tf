# Example: Spot-based Strata instance for cost-optimized ephemeral workloads
# ~60-70% cheaper than on-demand, but may be interrupted.
#
# Usage:
#   terraform init
#   terraform apply -var="weights_snapshot_id=snap-..." -var="use_spot=true"

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

variable "weights_snapshot_id" {
  type    = string
  default = ""
}

variable "model" {
  type    = string
  default = "UD-Q6_K_XL"
}

variable "instance_type" {
  description = "g6e.12xlarge for large models (4×L40S, 384GB RAM)"
  type        = string
  default     = "g6e.12xlarge"
}

variable "spot_max_price" {
  description = "Max hourly spot price (leave empty for on-demand ceiling)"
  type        = string
  default     = ""
}

module "strata" {
  source = "../../"

  name_prefix    = "strata-spot"
  region         = var.region
  instance_type  = var.instance_type
  model          = var.model
  model_family   = "qwen"
  context_length = "128k"

  use_spot       = true
  spot_max_price = var.spot_max_price

  weights_snapshot_id          = var.weights_snapshot_id
  data_volume_size             = 400
  enable_fast_snapshot_restore = true
  provisioned_iops             = 16000
  provisioned_throughput       = 1000

  allowed_cidr_blocks          = ["0.0.0.0/0"]
  associate_public_ip          = true
  ttl_minutes                  = 120
  health_check_timeout_seconds = 900

  tags = {
    Environment = "ephemeral"
    CostClass   = "spot"
  }
}

output "endpoint" {
  value = module.strata.api_endpoint
}
