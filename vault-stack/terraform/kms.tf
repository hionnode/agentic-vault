data "aws_caller_identity" "current" {}

# --- OpenBao Auto-Unseal KMS Key ---

resource "aws_kms_key" "openbao_unseal" {
  description             = "OpenBao auto-unseal key"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowKeyAdministration"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowOpenBaoUnseal"
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_role.openbao_instance.arn
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:DescribeKey"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "kms:ViaService" = "ec2.${var.aws_region}.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = {
    Purpose = "openbao-auto-unseal"
  }
}

resource "aws_kms_alias" "openbao_unseal" {
  name          = "alias/openbao-unseal"
  target_key_id = aws_kms_key.openbao_unseal.id
}
