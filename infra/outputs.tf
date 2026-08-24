output "aws_region" { value = var.aws_region }
output "cache_bucket_name" { value = aws_s3_bucket.cache.id }
output "cache_url" { value = "https://${aws_cloudfront_distribution.cache.domain_name}" }
output "cache_public_key" { value = var.cache_public_key }
output "cache_local_public_key" { value = var.local_cache_public_key }
output "cache_signing_secret_arn" { value = aws_secretsmanager_secret.cache_signing_key.arn }
output "cache_local_signing_secret_arn" { value = aws_secretsmanager_secret.cache_local_signing_key.arn }
output "github_provisioner_role_arn" { value = aws_iam_role.github_provisioner.arn }
output "github_image_builder_role_arn" { value = aws_iam_role.github_image_builder.arn }
output "runner_instance_profile_name" { value = aws_iam_instance_profile.runner.name }
output "local_runner_instance_profile_name" { value = aws_iam_instance_profile.local_runner.name }
output "runner_security_group_id" { value = aws_security_group.runner.id }
output "runner_subnet_ids" { value = aws_subnet.builder[*].id }
output "runner_config_kms_key_arn" { value = aws_kms_key.runner_config.arn }
output "runner_root_volume_gb" { value = var.runner_root_volume_gb }
output "runner_root_volume_iops" { value = var.runner_root_volume_iops }
output "runner_root_volume_throughput" { value = var.runner_root_volume_throughput }
output "builder_ami_parameter" { value = aws_ssm_parameter.builder_ami.name }
output "builder_ami_parameters" { value = { for system, parameter in aws_ssm_parameter.builder_amis : system => parameter.name } }
output "build_lock_table" { value = aws_dynamodb_table.build_lock.name }
output "cost_alert_topic_arn" { value = aws_sns_topic.cost_alerts.arn }
output "monthly_budget_usd" { value = var.monthly_budget_usd }
output "identity_center_operator_policy_json" {
  description = "Inline policy for the centrally managed NixAwsBuildOperator permission set."
  value       = data.aws_iam_policy_document.local_operator.json
}
