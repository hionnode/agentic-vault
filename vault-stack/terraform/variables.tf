variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "ap-south-1"
}

variable "vpc_id" {
  description = "VPC ID for the Vault instance"
  type        = string
}

variable "subnet_id" {
  description = "Subnet ID for the Vault instance"
  type        = string
}

variable "route_table_id" {
  description = "Route table ID for S3 VPC endpoint"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type (t4g.micro or t4g.small recommended)"
  type        = string
  default     = "t4g.small"
}

variable "vault_version" {
  description = "Vault binary version to install — check releases.hashicorp.com for latest"
  type        = string
  default     = "1.18.2"
}

variable "tailscale_authkey" {
  description = "Tailscale auth key for the Vault instance (ephemeral, reusable recommended)"
  type        = string
  sensitive   = true
}

variable "alert_email" {
  description = "Email address for CloudWatch alarm notifications"
  type        = string
}

variable "admin_role_name" {
  description = "IAM role name for admin access (used in bucket policies)"
  type        = string
  default     = "admin"
}
