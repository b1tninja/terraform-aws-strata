# Example: On-demand ephemeral Strata instance with FSR-accelerated weights
# Usage:
#   terraform init
#   terraform apply -var="weights_snapshot_id=snap-0abc123..."
#   # ... use the API ...
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
  description = "Pre-created EBS snapshot ID with model weights"
  type        = string
  default     = ""
}

variable "model" {
  type    = string
  default = "IQ3_XXS"
}

variable "instance_type" {
  type    = string
  default = "g6e.8xlarge"
}

variable "allowed_cidr_blocks" {
  type    = list(string)
  default = ["0.0.0.0/0"]
}

variable "ttl_minutes" {
  description = "Auto-shutdown after this many minutes (0 = manual destroy)"
  type        = number
  default     = 60
}

module "strata" {
  source = "../../"

  name_prefix     = "strata-eph"
  region          = var.region
  instance_type   = var.instance_type
  model           = var.model
  model_family    = "qwen"
  context_length  = "128k"
  kv_quantization = "int8"
  vision_mode     = "off"

  weights_snapshot_id          = var.weights_snapshot_id
  data_volume_size             = 250
  enable_fast_snapshot_restore = true
  provisioned_iops             = 16000
  provisioned_throughput       = 1000

  allowed_cidr_blocks = var.allowed_cidr_blocks
  associate_public_ip = true

  ttl_minutes                  = var.ttl_minutes
  health_check_timeout_seconds = 600

  tags = {
    Environment = "ephemeral"
    Purpose     = "development"
  }
}

output "endpoint" {
  value = module.strata.api_endpoint
}

output "instance_id" {
  value = module.strata.instance_id
}

output "public_ip" {
  value = module.strata.public_ip
}
