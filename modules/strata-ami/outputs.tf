# ─── strata-ami module outputs ─────────────────────────────────────────────────

output "base_ami_id" {
  description = "The base DLAMI that the custom AMI was derived from"
  value       = data.aws_ami.base.id
}

output "ami_id" {
  description = "The AMI ID built by EC2 Image Builder"
  value       = length(aws_imagebuilder_image.strata.output_resources) > 0 ? tolist(aws_imagebuilder_image.strata.output_resources[0].amis)[0].image : ""
}

output "image_recipe_arn" {
  description = "The image recipe ARN"
  value       = aws_imagebuilder_image_recipe.strata.arn
}
