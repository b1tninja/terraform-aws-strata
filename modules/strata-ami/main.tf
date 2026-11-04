# ─── strata-ami module ─────────────────────────────────────────────────────────
# Creates a custom AMI with NVIDIA drivers, Docker, nvidia-container-toolkit,
# and the Strata container image pre-baked via EC2 Image Builder.

# ─── Find Base AMI ─────────────────────────────────────────────────────────────

data "aws_ami" "base" {
  most_recent = true
  owners      = var.base_ami_owners

  filter {
    name   = "name"
    values = [var.base_ami_name_pattern]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_region" "current" {}

# ─── IAM for Image Builder ─────────────────────────────────────────────────────

data "aws_iam_policy_document" "imagebuilder_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "imagebuilder" {
  name               = "${var.name_prefix}-imagebuilder-role"
  assume_role_policy = data.aws_iam_policy_document.imagebuilder_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "imagebuilder" {
  name = "${var.name_prefix}-imagebuilder-policy"
  role = aws_iam_role.imagebuilder.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = "s3:*", Resource = "*" },
      { Effect = "Allow", Action = ["ecr:*"], Resource = "*" },
      { Effect = "Allow", Action = ["ssm:GetParameter*"], Resource = "*" }
    ]
  })
}

resource "aws_iam_instance_profile" "imagebuilder" {
  name = "${var.name_prefix}-imagebuilder-profile"
  role = aws_iam_role.imagebuilder.name
}

# ─── Image Recipe (AWSTOE components) ──────────────────────────────────────────

resource "aws_imagebuilder_component" "install_docker" {
  name     = "${var.name_prefix}-install-docker"
  version  = "1.0.0"
  platform = "Linux"
  data     = filebase64("${path.module}/components/install-docker.yaml")
  tags     = var.tags
}

resource "aws_imagebuilder_component" "pull_strata_image" {
  name     = "${var.name_prefix}-pull-strata"
  version  = "1.0.0"
  platform = "Linux"
  data = base64encode(templatefile("${path.module}/components/pull-strata-image.yaml.tpl", {
    strata_image_tag = var.strata_image_tag
  }))
  tags = var.tags
}

resource "aws_imagebuilder_image_recipe" "strata" {
  name         = "${var.name_prefix}-ami-recipe"
  version      = "1.0.0"
  parent_image = data.aws_ami.base.id

  component {
    component_arn = aws_imagebuilder_component.install_docker.arn
  }

  component {
    component_arn = aws_imagebuilder_component.pull_strata_image.arn
  }

  tags = var.tags
}

# ─── Infrastructure Configuration ──────────────────────────────────────────────

resource "aws_imagebuilder_infrastructure_configuration" "strata" {
  name                          = "${var.name_prefix}-infra"
  instance_profile_name         = aws_iam_instance_profile.imagebuilder.name
  instance_types                = [var.build_instance_type]
  terminate_instance_on_failure = true

  subnet_id = var.subnet_id != "" ? var.subnet_id : null

  tags = var.tags
}

# ─── Distribution Configuration ────────────────────────────────────────────────

resource "aws_imagebuilder_distribution_configuration" "strata" {
  name = "${var.name_prefix}-dist"

  distribution {
    region = data.aws_region.current.region
  }

  tags = var.tags
}

# ─── Image Pipeline ────────────────────────────────────────────────────────────

resource "aws_imagebuilder_image_pipeline" "strata" {
  name                             = "${var.name_prefix}-pipeline"
  image_recipe_arn                 = aws_imagebuilder_image_recipe.strata.arn
  infrastructure_configuration_arn = aws_imagebuilder_infrastructure_configuration.strata.arn
  distribution_configuration_arn   = aws_imagebuilder_distribution_configuration.strata.arn

  tags = var.tags
}

# Trigger a build
resource "aws_imagebuilder_image" "strata" {
  image_recipe_arn                 = aws_imagebuilder_image_recipe.strata.arn
  infrastructure_configuration_arn = aws_imagebuilder_infrastructure_configuration.strata.arn
  distribution_configuration_arn   = aws_imagebuilder_distribution_configuration.strata.arn

  lifecycle {
    ignore_changes = [image_recipe_arn, infrastructure_configuration_arn, distribution_configuration_arn]
  }
}
