# --- SNS Topic ---

resource "aws_sns_topic" "vault_alerts" {
  name = "vault-alerts"
}

resource "aws_sns_topic_subscription" "vault_alerts_email" {
  topic_arn = aws_sns_topic.vault_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# --- Alarm 1: Instance Status Check ---

resource "aws_cloudwatch_metric_alarm" "status_check" {
  alarm_name          = "vault-status-check-failed"
  alarm_description   = "Vault EC2 instance failed status check"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  dimensions          = { InstanceId = aws_instance.vault.id }
  alarm_actions       = [aws_sns_topic.vault_alerts.arn]
  ok_actions          = [aws_sns_topic.vault_alerts.arn]
}

# --- Alarm 2: CPU Sustained High ---

resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "vault-cpu-high"
  alarm_description   = "Vault CPU above 90% for 10 minutes"
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = 90
  comparison_operator = "GreaterThanThreshold"
  dimensions          = { InstanceId = aws_instance.vault.id }
  alarm_actions       = [aws_sns_topic.vault_alerts.arn]
}

# --- Alarm 3: CPU Credit Balance Low ---

resource "aws_cloudwatch_metric_alarm" "cpu_credits_low" {
  alarm_name          = "vault-cpu-credits-low"
  alarm_description   = "CPU credit balance below 20 — throttling imminent"
  namespace           = "AWS/EC2"
  metric_name         = "CPUCreditBalance"
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 2
  threshold           = 20
  comparison_operator = "LessThanThreshold"
  dimensions          = { InstanceId = aws_instance.vault.id }
  alarm_actions       = [aws_sns_topic.vault_alerts.arn]
}

# --- Alarm 4: Disk Usage High (requires CloudWatch agent) ---

resource "aws_cloudwatch_metric_alarm" "disk_high" {
  alarm_name          = "vault-disk-usage-high"
  alarm_description   = "Vault disk usage above 80%"
  namespace           = "Vault"
  metric_name         = "disk_used_percent"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  dimensions = {
    InstanceId = aws_instance.vault.id
    path       = "/"
  }
  alarm_actions = [aws_sns_topic.vault_alerts.arn]
}

# --- Alarm 5: Memory Usage High (requires CloudWatch agent) ---

resource "aws_cloudwatch_metric_alarm" "memory_high" {
  alarm_name          = "vault-memory-high"
  alarm_description   = "Vault memory usage above 85%"
  namespace           = "Vault"
  metric_name         = "mem_used_percent"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  threshold           = 85
  comparison_operator = "GreaterThanThreshold"
  dimensions          = { InstanceId = aws_instance.vault.id }
  alarm_actions       = [aws_sns_topic.vault_alerts.arn]
}

# --- Alarm 6: KMS Errors ---

resource "aws_cloudwatch_metric_alarm" "kms_errors" {
  alarm_name          = "vault-kms-errors"
  alarm_description   = "KMS decrypt errors — Vault may fail to unseal on restart"
  namespace           = "AWS/KMS"
  metric_name         = "KMSKeyError"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.vault_alerts.arn]
}

# --- CloudWatch Log Groups ---

resource "aws_cloudwatch_log_group" "vault_audit" {
  name              = "/vault/audit"
  retention_in_days = 90
}

resource "aws_cloudwatch_log_group" "vault_system" {
  name              = "/vault/system"
  retention_in_days = 30
}
