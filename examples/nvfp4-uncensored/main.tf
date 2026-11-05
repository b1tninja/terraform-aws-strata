# Example: one model, two configurations.
#
# The routed experts are the expensive part. NVFP4 GPTQ is 128 GB of weights, and it
# is the same 128 GB whether the model declines your requests or not. The refusal
# direction is a 261 KiB control vector that the engine applies at load time, so this
# deployment differs from a stock one by one boolean:
#
#   terraform apply -var="uncensored=false"   # strata-nvfp4-nvfp4
#   terraform apply -var="uncensored=true"    # strata-nvfp4-nvfp4-uncensored
#
# Same instance type, same weights snapshot, same volume size, same image, same
# download. The vector is fetched at boot, checked against a pinned SHA-256, and
# written into the model's run config as user_args; the container restarts once and
# serves the same model directory under a name ending in -uncensored.
#
# Usage:
#   terraform init
#   terraform apply -var="weights_snapshot_id=snap-0abc123..."   # optional
#   curl -s http://$(terraform output -raw public_ip):8080/v1/models
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

variable "uncensored" {
  description = "false serves the model as published; true serves the same weights with the control vector applied"
  type        = bool
  default     = true
}

variable "weights_snapshot_id" {
  description = "EBS snapshot of a volume that already holds the NVFP4 weights. Omit to download them on first boot."
  type        = string
  default     = ""
}

variable "instance_type" {
  description = "sm_120 (Blackwell RTX) only, if you want the vector applied on FP4 tensor cores rather than in the 8-bit fallback path"
  type        = string
  default     = "g7e.8xlarge"
}

module "strata" {
  # The registry convention is to show the address an external caller would use:
  #   source = "github.com/b1tninja/terraform-aws-strata"
  # The relative path is used here so the example validates before that repository
  # exists; switch it when you copy this directory into your own project.
  source = "../../"

  name_prefix   = "strata-nvfp4"
  region        = var.region
  instance_type = var.instance_type

  model        = "NVFP4"
  model_family = "nvfp4"

  # The one line that matters for this example.
  uncensored = var.uncensored

  # data_volume_size is deliberately unset: the catalog derives 180 GiB for NVFP4
  # (download + conversion headroom), which both configurations share.
  weights_snapshot_id = var.weights_snapshot_id

  use_spot    = true
  ttl_minutes = 90

  tags = {
    Purpose = "one-model-two-configurations"
  }
}

output "endpoint" {
  description = "OpenAI-compatible base URL"
  value       = module.strata.api_endpoint
}

output "public_ip" {
  value = module.strata.public_ip
}

output "uncensored" {
  description = "Which of the two configurations this endpoint serves"
  value       = module.strata.uncensored
}

output "control_vector" {
  description = "The pinned bytes that make this configuration differ from the stock one"
  value       = module.strata.control_vector
}
