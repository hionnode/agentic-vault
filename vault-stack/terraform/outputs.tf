output "openbao_instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.openbao.id
}

output "openbao_instance_private_ip" {
  description = "Private IP (use Tailscale MagicDNS for access instead)"
  value       = aws_instance.openbao.private_ip
}

output "openbao_instance_profile" {
  description = "IAM instance profile name"
  value       = aws_iam_instance_profile.openbao.name
}

output "openbao_unseal_key_arn" {
  description = "KMS key ARN used for OpenBao auto-unseal"
  value       = aws_kms_key.openbao_unseal.arn
}

output "backup_bucket_name" {
  description = "S3 bucket for Raft snapshots"
  value       = aws_s3_bucket.openbao_backups.id
}

output "backup_kms_key_arn" {
  description = "KMS key ARN for backup encryption"
  value       = aws_kms_key.openbao_backup.arn
}

output "sns_topic_arn" {
  description = "SNS topic ARN for OpenBao alerts"
  value       = aws_sns_topic.openbao_alerts.arn
}

output "security_group_id" {
  description = "Security group ID for the OpenBao instance"
  value       = aws_security_group.openbao.id
}
