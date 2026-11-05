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

output "api_key" {
  description = "API key for the endpoint (null when it comes from a pre-existing Secrets Manager secret)"
  value       = var.use_secrets_manager && var.secrets_manager_secret_id != "" ? null : local.api_key
  sensitive   = true
}

output "api_key_secret_arn" {
  description = "Secrets Manager ARN holding the API key, when use_secrets_manager is enabled"
  value       = local.api_key_secret_arn
  sensitive   = true
}

output "ttl_terminate_schedule_arn" {
  description = "EventBridge Scheduler schedule that terminates the instance at TTL expiry (null when disabled)"
  value       = local.scheduler_enabled ? aws_scheduler_schedule.ttl_terminate[0].arn : null
}
