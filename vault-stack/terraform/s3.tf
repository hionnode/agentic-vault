# --- Backup KMS Key (separate from unseal key) ---

resource "aws_kms_key" "vault_backup" {
  description             = "Vault Raft backup encryption"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = {
    Purpose = "vault-backup-encryption"
  }
}

resource "aws_kms_alias" "vault_backup" {
  name          = "alias/vault-backup"
  target_key_id = aws_kms_key.vault_backup.id
}

# --- Backup Bucket ---

resource "aws_s3_bucket" "vault_backups" {
  bucket = "vault-raft-backups-${data.aws_caller_identity.current.account_id}"

  tags = {
    Purpose = "vault-raft-backups"
  }
}

resource "aws_s3_bucket_versioning" "vault_backups" {
  bucket = aws_s3_bucket.vault_backups.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "vault_backups" {
  bucket = aws_s3_bucket.vault_backups.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.vault_backup.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "vault_backups" {
  bucket = aws_s3_bucket.vault_backups.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "vault_backups" {
  bucket = aws_s3_bucket.vault_backups.id

  rule {
    id     = "backup-lifecycle"
    status = "Enabled"

    filter {
      prefix = "snapshots/"
    }

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 60
      storage_class = "GLACIER"
    }

    expiration {
      days = 90
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

resource "aws_s3_bucket_policy" "vault_backups" {
  bucket = aws_s3_bucket.vault_backups.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyDeleteFromAll"
        Effect    = "Deny"
        Principal = "*"
        Action = [
          "s3:DeleteObject",
          "s3:DeleteBucket",
          "s3:PutBucketPolicy"
        ]
        Resource = [
          aws_s3_bucket.vault_backups.arn,
          "${aws_s3_bucket.vault_backups.arn}/*"
        ]
      },
      {
        Sid       = "DenyUnauthorizedAccess"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.vault_backups.arn,
          "${aws_s3_bucket.vault_backups.arn}/*"
        ]
        Condition = {
          StringNotEquals = {
            "aws:PrincipalArn" = [
              aws_iam_role.vault_instance.arn,
              "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.admin_role_name}"
            ]
          }
        }
      }
    ]
  })
}
