# Example: one model, two behaviours, chosen per request.
#
# The routed experts are the expensive part: NVFP4 is 128 GB. What decides whether the
# model declines a request is a 267,552-byte control vector that the engine applies while
# generating, so the steered behaviour is not a second model - it is not even a second
# deployment. Load the vector once and this one endpoint serves both:
#
#   curl $EP/v1/chat/completions \
#     -d '{"model":"m","messages":[{"role":"user","content":"..."}]}'
#   # stock: token for token the original model, because default_on = false wrote
#   # "sampling": {"experimental_speed_projection": false} into the run config.
#
#   curl $EP/v1/chat/completions \
#     -d '{"model":"m","experimental_speed_projection":true,"messages":[...]}'
#   # projection on for this request only.
#
# Nothing is re-downloaded: same volume, same snapshot, same image, same model name.
#
# Usage:
#   terraform init
#   terraform apply                                   # downloads weights on first boot
#   terraform apply -var="weights_snapshot_id=snap-0abc123..."   # or restore a snapshot
#   terraform output request_switch                   # what the caller sends to choose
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
  description = "EBS snapshot of a volume that already holds the NVFP4 weights. Omit to download them on first boot."
  type        = string
  default     = ""
}

variable "instance_type" {
  description = "sm_120 (Blackwell RTX) if you want the projection on FP4 tensor cores rather than in the 8-bit fallback path"
  type        = string
  default     = "g7e.8xlarge"
}

variable "default_on" {
  description = "false keeps the endpoint stock until a caller asks for the projection; true makes the projection the default and a caller opts out"
  type        = bool
  default     = false
}

# The hook. It holds the pins, runs the lineage and licence gates, and renders the shell
# fragment that the core module splices in after the model is healthy.
module "steer" {
  source = "../../modules/strata-control-vector"

  model        = "NVFP4"
  model_family = "nvfp4"

  default_on = var.default_on
}

module "strata" {
  # Registry convention is the address an external caller would use:
  #   source = "github.com/b1tninja/terraform-aws-strata"
  # The relative path is used here so the example validates before that repository
  # exists; switch it when you copy this directory into your own project.
  source = "../../"

  name_prefix   = "strata-nvfp4"
  region        = var.region
  instance_type = var.instance_type

  model        = "NVFP4"
  model_family = "nvfp4"

  # The one line that adds the second behaviour. The core knows only that a hook is a
  # shell fragment to splice in after the health check - it has no idea what this one does.
  boot_hooks = [module.steer.boot_hook]

  # data_volume_size deliberately unset: the catalog derives 180 GiB for NVFP4, and both
  # behaviours read the same bytes from it.
  weights_snapshot_id = var.weights_snapshot_id

  use_spot    = true
  ttl_minutes = 90

  tags = {
    Purpose = "one-model-two-behaviours"
  }
}

output "endpoint" {
  description = "OpenAI-compatible base URL serving both behaviours"
  value       = module.strata.api_endpoint
}

output "public_ip" {
  value = module.strata.public_ip
}

output "request_switch" {
  description = "What a caller sends to choose the behaviour for one request"
  value       = module.steer.request_switch
}

output "control_vector" {
  description = "The pinned bytes that make the second behaviour possible, and the licence ground it stands on"
  value       = module.steer.control_vector
}

output "boot_hooks" {
  description = "Proof from the plan that the hook reached the deployment"
  value       = module.strata.boot_hooks
}
