# Example: two configurations, one snapshot.
#
# Because the uncensored variant is a steering vector rather than a model, both
# configurations can boot from the SAME EBS snapshot of weights. Neither one downloads
# 128 GB: the snapshot is created once (examples/full-pipeline, or the bundled AMI) and
# every deployment after that pays for GPU time only.
#
# This gives you two OpenAI-compatible endpoints whose /v1/models reports
# strata-nvfp4-nvfp4 and strata-nvfp4-nvfp4-uncensored, with exactly one set of model
# bytes in the account.
#
# Usage:
#   terraform init
#   terraform apply -var="weights_snapshot_id=snap-0abc123..."
#   terraform output -json | jq '{stock: .stock_endpoint.value, uncensored: .uncensored_endpoint.value}'
#   terraform destroy

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
  description = "Snapshot of a volume holding the NVFP4 weights. Both deployments restore from it."
  type        = string
}

variable "instance_type" {
  type    = string
  default = "g7e.8xlarge"
}

variable "ttl_minutes" {
  description = "Both instances terminate on this timer; two GPUs are not something to leave running"
  type        = number
  default     = 45
}

locals {
  # Everything except the name and the boolean below is identical, and that is the
  # entire point: the weights, the snapshot and the volume size are shared.
  common = {
    region              = var.region
    instance_type       = var.instance_type
    model               = "NVFP4"
    model_family        = "nvfp4"
    weights_snapshot_id = var.weights_snapshot_id
    use_spot            = true
    ttl_minutes         = var.ttl_minutes
  }
}

module "stock" {
  source = "../../"

  name_prefix         = "strata-stock"
  region              = local.common.region
  instance_type       = local.common.instance_type
  model               = local.common.model
  model_family        = local.common.model_family
  weights_snapshot_id = local.common.weights_snapshot_id
  use_spot            = local.common.use_spot
  ttl_minutes         = local.common.ttl_minutes

  uncensored = false

  tags = {
    Role = "stock-configuration"
  }
}

module "uncensored" {
  source = "../../"

  name_prefix         = "strata-steered"
  region              = local.common.region
  instance_type       = local.common.instance_type
  model               = local.common.model
  model_family        = local.common.model_family
  weights_snapshot_id = local.common.weights_snapshot_id
  use_spot            = local.common.use_spot
  ttl_minutes         = local.common.ttl_minutes

  uncensored = true

  tags = {
    Role = "control-vector-configuration"
  }
}

output "stock_endpoint" {
  description = "Endpoint serving the model exactly as published"
  value       = module.stock.api_endpoint
}

output "uncensored_endpoint" {
  description = "Endpoint serving the same weights with the control vector applied"
  value       = module.uncensored.api_endpoint
}

output "weights_snapshot_id" {
  description = "The single set of model bytes both endpoints boot from"
  value       = var.weights_snapshot_id
}

output "difference" {
  description = "What makes the two deployments differ"
  value = {
    extra_bytes_per_instance = 267552
    extra_model_downloads    = 0
    vector_sha256            = module.uncensored.control_vector.vector_sha256
  }
}
