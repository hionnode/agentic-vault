# --- AMI Data Source ---

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "architecture"
    values = ["arm64"]
  }
}

# --- Vault EC2 Instance ---

resource "aws_instance" "vault" {
  ami                  = data.aws_ami.ubuntu.id
  instance_type        = var.instance_type
  iam_instance_profile = aws_iam_instance_profile.vault.name
  monitoring           = true # Detailed monitoring (1-min metrics)

  vpc_security_group_ids = [aws_security_group.vault.id]
  subnet_id              = var.subnet_id

  root_block_device {
    volume_size           = 30
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
    tags                  = { Name = "vault-root" }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 enforced
    http_put_response_hop_limit = 1          # Prevent container/proxy SSRF
    instance_metadata_tags      = "disabled"
  }

  user_data_base64 = base64encode(templatefile("${path.module}/../scripts/user-data.sh", {
    vault_version    = var.vault_version
    kms_key_id       = aws_kms_key.vault_unseal.id
    aws_region       = var.aws_region
    tailscale_authkey = var.tailscale_authkey
    backup_bucket    = aws_s3_bucket.vault_backups.id
    backup_kms_key   = aws_kms_key.vault_backup.arn
  }))

  tags = {
    Name = "vault"
  }

  lifecycle {
    ignore_changes = [ami, user_data_base64]
  }
}
