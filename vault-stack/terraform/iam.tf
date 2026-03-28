# --- OpenBao Instance Role ---

resource "aws_iam_role" "openbao_instance" {
  name = "openbao-instance-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Purpose = "openbao-ec2-instance"
  }
}

resource "aws_iam_instance_profile" "openbao" {
  name = "openbao-instance-profile"
  role = aws_iam_role.openbao_instance.name
}

# --- KMS Unseal Policy ---
# Conditions are on the key policy (kms.tf), not duplicated here

resource "aws_iam_role_policy" "openbao_kms" {
  name = "openbao-kms-unseal"
  role = aws_iam_role.openbao_instance.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:DescribeKey"
        ]
        Resource = aws_kms_key.openbao_unseal.arn
      }
    ]
  })
}

# --- S3 Backup Policy (append-only from instance perspective) ---

resource "aws_iam_role_policy" "openbao_s3_backup" {
  name = "openbao-s3-backup"
  role = aws_iam_role.openbao_instance.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.openbao_backups.arn,
          "${aws_s3_bucket.openbao_backups.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:GenerateDataKey"
        ]
        Resource = aws_kms_key.openbao_backup.arn
      }
    ]
  })
}

# --- SSM Managed Instance Core ---

resource "aws_iam_role_policy_attachment" "openbao_ssm" {
  role       = aws_iam_role.openbao_instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# --- CloudWatch Agent Policy ---

resource "aws_iam_role_policy_attachment" "openbao_cloudwatch" {
  role       = aws_iam_role.openbao_instance.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}
