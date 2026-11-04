# tflint configuration for strata-terraform
# https://github.com/terraform-linters/tflint

plugin "aws" {
  enabled = true
  version = "0.38.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

# Allow variable references in resource names (common in modules)
rule "terraform_naming_convention" {
  enabled = true
}

# We use dynamic blocks which can trip the unused-declaration rule
rule "terraform_unused_declarations" {
  enabled = true
}
