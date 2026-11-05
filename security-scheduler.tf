# ─── Secrets Manager ───────────────────────────────────────────────────────────
# Store the API key in Secrets Manager rather than baking it into user_data.
# The instance fetches it at boot via IAM (instance profile has GetSecretValue).

# ─── API Key Secret Resolution ─────────────────────────────────────────────────
# use_secrets_manager = true supports two modes:
#   secrets_manager_secret_id = ""  -> create and manage the secret here
#   secrets_manager_secret_id set   -> reference a pre-existing secret (name or ARN)
# Either way the instance fetches the key at boot with its instance profile, so the
# key never appears in user_data, process listings, or the boot log.

locals {
  create_api_key_secret = var.use_secrets_manager && var.secrets_manager_secret_id == ""

  # Handed to the boot script; get-secret-value accepts an ARN or a name.
  api_key_secret_id = local.create_api_key_secret ? aws_secretsmanager_secret.api_key[0].arn : var.secrets_manager_secret_id

  # ARN for the instance policy. Secrets Manager appends a 6-char suffix to names, so a
  # name-based ARN needs a trailing wildcard to match the real secret.
  api_key_secret_arn = local.create_api_key_secret ? aws_secretsmanager_secret.api_key[0].arn : (
    var.use_secrets_manager ? (
      startswith(var.secrets_manager_secret_id, "arn:") ? var.secrets_manager_secret_id :
      "arn:aws:secretsmanager:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:secret:${var.secrets_manager_secret_id}*"
    ) : null
  )
}

resource "aws_secretsmanager_secret" "api_key" {
  count                   = local.create_api_key_secret ? 1 : 0
  name                    = "${var.name_prefix}/api-key/${var.model}"
  description             = "Strata API key for model ${var.model} (${var.model_family})"
  recovery_window_in_days = 0 # Allow immediate delete for ephemeral deployments

  tags = local.common_tags
}

# JSON shape, so a pre-existing secret and a Terraform-managed one look identical
# to the boot script.
resource "aws_secretsmanager_secret_version" "api_key" {
  count         = local.create_api_key_secret ? 1 : 0
  secret_id     = aws_secretsmanager_secret.api_key[0].id
  secret_string = jsonencode({ api_key = local.api_key })
}

# Grant the instance role permission to read the secret
resource "aws_iam_role_policy" "secrets_access" {
  count = var.use_secrets_manager ? 1 : 0
  name  = "${var.name_prefix}-secrets-access"
  role  = aws_iam_role.strata_instance.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = local.api_key_secret_arn
    }]
  })
}

# ─── EventBridge Scheduler for TTL Termination ─────────────────────────────────
# More reliable than cloud-init shutdown: fires even if the instance is stuck.
# Terminates the instance at (now + ttl_minutes) using the EC2 TerminateInstances API.

locals {
  scheduler_enabled  = var.ttl_minutes > 0 && var.use_eventbridge_scheduler
  strata_instance_id = var.use_spot ? aws_instance.strata_spot[0].id : aws_instance.strata[0].id
}

# Freezes the deployment instant. Using timestamp() inline would shift on every plan
# and force a new schedule each time.
resource "time_static" "deployment" {
  count = local.scheduler_enabled ? 1 : 0
}

resource "aws_iam_role" "scheduler" {
  count = local.scheduler_enabled ? 1 : 0
  name  = "${var.name_prefix}-scheduler-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "scheduler_terminate" {
  count = local.scheduler_enabled ? 1 : 0
  name  = "${var.name_prefix}-scheduler-terminate"
  role  = aws_iam_role.scheduler[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ec2:TerminateInstances"]
      Resource = concat(aws_instance.strata[*].arn, aws_instance.strata_spot[*].arn)
      Condition = {
        StringEquals = {
          "aws:RequestedRegion" = data.aws_region.current.region
        }
      }
    }]
  })
}

resource "aws_scheduler_schedule" "ttl_terminate" {
  count = local.scheduler_enabled ? 1 : 0

  # Derived from the instance ID: unique per deployment, stable across plans, and
  # within the [0-9a-zA-Z-_.]+ / 64-char limit for schedule names.
  name       = "${var.name_prefix}-ttl-${substr(replace(local.strata_instance_id, "/^i-/", ""), 0, 17)}"
  group_name = "default"

  flexible_time_window {
    mode = "OFF"
  }

  # One-time: fire at (deployment instant + TTL). at() takes a plain UTC timestamp with
  # no Z designator; formatdate needs 'T' single-quoted or it errors as an invalid verb.
  schedule_expression          = "at(${formatdate("YYYY-MM-DD'T'hh:mm:ss", timeadd(time_static.deployment[0].rfc3339, "${var.ttl_minutes}m"))})"
  schedule_expression_timezone = "UTC"

  # Remove the schedule once it has fired — nothing to keep for an ephemeral deployment.
  action_after_completion = "DELETE"

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:terminateInstances"
    role_arn = aws_iam_role.scheduler[0].arn

    input = jsonencode({
      InstanceIds = [local.strata_instance_id]
    })
  }
}
