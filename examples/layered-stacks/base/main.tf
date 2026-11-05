# Base stack: the model artefact.
#
# Apply this first. It owns the expensive, slow, rarely-changing thing - 128 GB of
# weights converted into an EBS snapshot - and exports one ID. The
# ../uncensored stack reads that ID through terraform_remote_state, so a serving policy
# can be created, changed and destroyed without ever touching the model bytes.
#
# Keeping them in separate states is what makes "one model, two configurations" an
# operational fact rather than a slogan: the steered stack has no way to disturb the
# stock one, and destroying it cannot delete a snapshot it does not own.
#
# Usage:
#   terraform init
#   terraform apply -var="subnet_id=subnet-0abc123..."
#   terraform output weights_snapshot_id
#   cd ../uncensored && terraform init && terraform apply

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

variable "model" {
  type    = string
  default = "NVFP4"
}

variable "model_family" {
  type    = string
  default = "nvfp4"
}

variable "volume_size" {
  description = "Size of the staging volume the weights land on. The catalog derives 180 GiB for NVFP4; the snapshot is that size."
  type        = number
  default     = 180
}

variable "subnet_id" {
  description = "Subnet for the staging instance that downloads the weights"
  type        = string
}

variable "availability_zone" {
  description = "Choose this so the snapshot restores fast in the zone your instances will run in"
  type        = string
  default     = "us-east-1a"
}

module "weights" {
  source = "../../../modules/strata-data-snapshot"

  name_prefix           = "strata-weights-${var.model}"
  region                = var.region
  model                 = var.model
  model_family          = var.model_family
  volume_size           = var.volume_size
  availability_zones    = [var.availability_zone]
  staging_instance_type = "c6i.xlarge"
  staging_subnet_id     = var.subnet_id
  enable_fsr            = true

  tags = {
    Stack = "base"
    Role  = "weights-artefact"
  }
}

output "weights_snapshot_id" {
  description = "What the serving stacks consume. Nothing in this example downloads the model twice."
  value       = module.weights.snapshot_id
}

output "model" {
  description = "Recorded so a serving stack can assert it matches what it steers"
  value       = var.model
}

output "model_family" {
  description = "Recorded so a serving stack can assert the licence and lineage gates against what actually boots"
  value = var.model_family
}

output "volume_size" {
  description = "The snapshot's volume size, so a serving stack does not have to guess how big to make its volume"
  value = var.volume_size
}
