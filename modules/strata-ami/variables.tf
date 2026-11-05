variable "name_prefix" {
  description = "Resource name prefix"
  type        = string
  default     = "strata"
}

variable "strata_image_tag" {
  description = "Docker image tag to bake into the AMI. Pinned by default; see the root module's variable of the same name for the tag list and why moving tags are avoided."
  type        = string
  default     = "0.2.9-cuda13"
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
  description = <<-EOT
    Instance type used for the Image Builder build phase.

    This does not need a GPU. Both build components are CPU and network work:
    components/install-docker.yaml installs Docker and configures nvidia-container-toolkit
    (nvidia-ctk runtime configure writes a daemon config; it does not touch a card), and
    components/pull-strata-image.yaml.tpl runs docker pull and docker image inspect. The
    CUDA drivers and toolkit land in the image from the Deep Learning base AMI, which is
    selected by data source, not built here, so nothing about the artefact depends on the
    build instance having a GPU.

    An AMI is architecture-dependent, not instance-family dependent: build on x86_64 here
    and boot it on g7e later. Keep the architecture matched, and keep the root volume big
    enough for the pulled image.

    Set this back to a GPU type only if you add a build step that genuinely probes a card.
  EOT
  type        = string
  default     = "c6i.2xlarge"
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
