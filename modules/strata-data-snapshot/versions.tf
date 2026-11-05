# Floor stated locally because this submodule is consumable on its own; see the note in
# modules/strata-ami/versions.tf. Constraints mirror the root module.
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.30.0"
    }
  }
}
