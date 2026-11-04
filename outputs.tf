output "instance_id" {
  description = "ID of the running Strata instance"
  value       = var.use_spot ? null : aws_instance.strata[0].id
}

output "public_ip" {
  description = "Public IP address of the instance"
  value       = var.use_spot ? null : aws_instance.strata[0].public_ip
}

output "private_ip" {
  description = "Private IP address of the instance"
  value       = var.use_spot ? null : aws_instance.strata[0].private_ip
}

output "api_endpoint" {
  description = "OpenAI-compatible API endpoint URL"
  value       = var.use_spot ? null : "http://${aws_instance.strata[0].public_ip}:8080"
}

output "anthropic_endpoint" {
  description = "Anthropic-compatible API endpoint URL"
  value       = var.use_spot ? null : "http://${aws_instance.strata[0].public_ip}:8080"
}

output "security_group_id" {
  description = "Security group ID"
  value       = aws_security_group.strata.id
}

output "launch_template_id" {
  description = "Launch template ID (for external orchestration)"
  value       = aws_launch_template.strata.id
}

output "iam_instance_profile_arn" {
  description = "IAM instance profile ARN"
  value       = aws_iam_instance_profile.strata.arn
}

output "data_volume_id" {
  description = "Data EBS volume ID"
  value       = var.use_spot ? null : aws_instance.strata[0].root_block_device[0].volume_id
}
