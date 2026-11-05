# Uncensored stack: one model's second configuration, in its own state.
#
# Everything about the model comes from the base stack: the snapshot ID, the size, the
# family. What this stack adds is a 267,552-byte control vector and the two gates that
# decide whether it may be used. Applying, changing or destroying it never touches the
# weights, and it cannot disturb a stock stack that restores from the same snapshot.
#
# default_on = true because this stack exists to serve steered traffic; a caller that
# wants the original model for one request passes
# "experimental_speed_projection": false and gets it token for token.
#
# Usage (after the base stack has been applied):
#   terraform init
#   terraform apply
#   curl -s $(terraform output -raw steered_endpoint)/v1/models
#   terraform destroy        # the snapshot survives this

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

# The base stack's outputs. backend = "local" reads ../base/terraform.tfstate, which is
# fine for a laptop and keeps this example self-contained; in real use point both stacks
# at S3 (see the README) and use backend = "s3" here.
data "terraform_remote_state" "base" {
  backend = "local"

  config = {
    path = "${path.module}/../base/terraform.tfstate"
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "instance_type" {
  type    = string
  default = "g7e.8xlarge"
}

variable "subnet_id" {
  description = "Subnet for the serving instance"
  type        = string
}

variable "allowed_cidr_blocks" {
  type    = list(string)
  default = ["0.0.0.0/0"]
}

variable "ttl_minutes" {
  type    = number
  default = 90
}

# The gates read the same model the base stack produced, so a snapshot of some other
# model cannot be steered by accident: the licence and lineage checks run here, at plan
# time, against the catalog entry for what is about to boot.
module "steer" {
  source = "../../../modules/strata-control-vector"

  model        = data.terraform_remote_state.base.outputs.model
  model_family = data.terraform_remote_state.base.outputs.model_family

  default_on        = true
  separate_endpoint = true
}

module "strata" {
  # Registry convention is the address an external caller would use:
  #   source = "github.com/b1tninja/terraform-aws-strata"
  source = "../../../"

  name_prefix   = "strata-steered"
  region        = var.region
  subnet_id     = var.subnet_id
  instance_type = var.instance_type

  model        = data.terraform_remote_state.base.outputs.model
  model_family = data.terraform_remote_state.base.outputs.model_family

  boot_hooks = [module.steer.boot_hook]

  weights_snapshot_id = data.terraform_remote_state.base.outputs.weights_snapshot_id
  data_volume_size    = data.terraform_remote_state.base.outputs.volume_size

  allowed_cidr_blocks = var.allowed_cidr_blocks
  associate_public_ip = true

  use_spot    = true
  ttl_minutes = var.ttl_minutes

  tags = {
    Stack         = "uncensored"
    BaseStack     = data.terraform_remote_state.base.outputs.weights_snapshot_id
    Configuration = "refusal-direction projection, on by default"
  }
}

output "steered_endpoint" {
  description = "OpenAI-compatible endpoint with the vector loaded"
  value       = module.strata.api_endpoint
}

output "request_switch" {
  description = "How a caller opts out of the projection for a single request"
  value       = module.steer.request_switch
}

output "control_vector" {
  description = "The pinned bytes this stack fetches, and the licence it stands on"
  value       = module.steer.control_vector
}

output "weights_snapshot_id" {
  description = "Owned by the base stack; destroying this one leaves it alone"
  value       = data.terraform_remote_state.base.outputs.weights_snapshot_id
}
