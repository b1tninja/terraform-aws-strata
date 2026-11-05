# Example: two deployments, one snapshot - for when you need isolation, not duplication.
#
# The per-request switch (examples/nvfp4-uncensored) is usually the right answer: one
# endpoint, both behaviours. Reach for this shape when the two configurations must not
# share a process at all - a separate security group, a different TTL, an auditable
# endpoint that only ever runs stock.
#
# What is still shared is the thing that costs money to produce: both deployments restore
# from the SAME weights snapshot, and neither downloads 128 GB. The steered one also
# renames itself with -uncensored (separate_endpoint), so /v1/models on the two endpoints
# differ.
#
# Usage:
#   terraform init
#   terraform apply -var="weights_snapshot_id=snap-0abc123..."
#   terraform output -json | jq '{stock: .stock_endpoint.value, steered: .steered_endpoint.value}'
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

# Only the steered deployment needs a hook, so only it needs the module. Its gates read
# the same model/family pair the core module will deploy.
module "steer" {
  source = "../../modules/strata-control-vector"

  model        = "NVFP4"
  model_family = "nvfp4"

  # Different processes, so each needs one unambiguous name.
  separate_endpoint = true
}

module "stock" {
  source = "../../"

  name_prefix   = "strata-stock"
  region        = var.region
  instance_type = var.instance_type

  model        = "NVFP4"
  model_family = "nvfp4"

  weights_snapshot_id = var.weights_snapshot_id
  use_spot            = true
  ttl_minutes         = var.ttl_minutes

  tags = {
    Role = "stock-only"
  }
}

module "steered" {
  source = "../../"

  name_prefix   = "strata-steered"
  region        = var.region
  instance_type = var.instance_type

  model        = "NVFP4"
  model_family = "nvfp4"

  boot_hooks = [module.steer.boot_hook]

  weights_snapshot_id = var.weights_snapshot_id
  use_spot            = true
  ttl_minutes         = var.ttl_minutes

  tags = {
    Role = "projection-loaded"
  }
}

output "stock_endpoint" {
  description = "Serves the model exactly as published, and has no vector loaded at all"
  value       = module.stock.api_endpoint
}

output "steered_endpoint" {
  description = "Has the vector loaded; projection chosen per request, stock by default"
  value       = module.steered.api_endpoint
}

output "weights_snapshot_id" {
  description = "The single set of model bytes both endpoints boot from"
  value       = var.weights_snapshot_id
}

output "difference" {
  description = "What separates the two deployments"
  value = {
    vector_bytes_per_instance = 267552
    extra_model_downloads     = 0
    vector_sha256             = module.steer.control_vector.vector_sha256
  }
}
