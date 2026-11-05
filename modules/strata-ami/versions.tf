# Declared here rather than inherited: this directory is published as part of the module and can be
# consumed on its own (the registry generates a page per submodule), and tflint's
# terraform_required_version / terraform_required_providers rules are right that a module with no
# stated floor can be opened by a Terraform too old to parse it.
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.30.0"
    }
  }
}
