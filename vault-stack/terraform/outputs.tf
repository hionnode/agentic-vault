output "vault_instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.vault.id
}

output "vault_instance_private_ip" {
  description = "Private IP (use Tailscale MagicDNS for access instead)"
  value       = aws_instance.vault.private_ip
}

output "vault_instance_profile" {
  description = "IAM instance profile name"
  value       = aws_iam_instance_profile.vault.name
}

output "vault_unseal_key_arn" {
  description = "KMS key ARN used for Vault auto-unseal"
  value       = aws_kms_key.vault_unseal.arn
}

output "backup_bucket_name" {
  description = "S3 bucket for Raft snapshots"
  value       = aws_s3_bucket.vault_backups.id
}

output "backup_kms_key_arn" {
  description = "KMS key ARN for backup encryption"
  value       = aws_kms_key.vault_backup.arn
}

output "sns_topic_arn" {
  description = "SNS topic ARN for Vault alerts"
  value       = aws_sns_topic.vault_alerts.arn
}

output "security_group_id" {
  description = "Security group ID for the Vault instance"
  value       = aws_security_group.vault.id
}
