variable "name_prefix" {
  description = "Resource name prefix"
  type        = string
  default     = "strata"
}

variable "strata_image_tag" {
  description = "Docker image tag to bake into the AMI"
  type        = string
  default     = "latest-cuda13"
}

variable "base_ami_owners" {
  description = "Owners to search for the base AMI"
  type        = list(string)
  default     = ["amazon"]
}

variable "base_ami_name_pattern" {
  description = "Name pattern for the base AMI (Deep Learning Base OSS)"
  type        = string
  default     = "Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 24.04)*"
}

variable "build_instance_type" {
  description = "Instance type used for the Image Builder build phase"
  type        = string
  default     = "g6e.xlarge"
}

variable "subnet_id" {
  description = "Subnet for the build instance"
  type        = string
  default     = ""
}

variable "tags" {
  description = "Common tags"
  type        = map(string)
  default     = {}
}
