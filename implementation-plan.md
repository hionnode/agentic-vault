# OpenBao Infrastructure — Implementation Plan

## Overview

A single-node OpenBao deployment on AWS EC2, accessed exclusively over Tailscale, with KMS auto-unseal and S3-backed Raft snapshots. Designed as a centralised secrets manager for agentic coding workflows, homelab infrastructure, and cloud workloads.

**Target cost:** ~$20/month minimal, ~$41/month with full monitoring (see Phase 6.4)

> **Licensing note:** We use [OpenBao](https://openbao.org), the open-source (MPL 2.0) Linux Foundation fork of HashiCorp Vault. OpenBao is community-maintained and API-compatible with Vault.

---

## How to Use This Document

This is the complete build plan for Agentic Vault. It serves multiple audiences:

- **Deploying your own instance:** Follow Phases 0-6 sequentially. Each phase builds on the previous one. Budget 2-3 hours for a first deployment.
- **Understanding the architecture:** Read the Architecture section and Phase 4 (OpenBao Configuration) for the security model and integration patterns. See also [`docs/integration-patterns.md`](docs/integration-patterns.md) for the full pattern reference.
- **Contributing to the MCP server:** Phase 8 describes the OpenBao MCP server design — the most community-relevant component.

### Phase Status

| Phase | Description | Status |
|-------|-------------|--------|
| 0 | Prerequisites (tooling, AWS, Tailscale, state bucket) | Built |
| 1 | Terraform foundation (KMS, S3, IAM, networking) | Built |
| 2 | Instance provisioning (EC2, cloud-init, OpenBao install) | Built |
| 3 | Tailscale network hardening | Built |
| 4 | OpenBao configuration (auth, secrets engines, policies) | Built |
| 5 | Backup and disaster recovery | Built |
| 6 | Ongoing operations (monitoring, alerting, runbook) | Built |
| 7 | Harness engineering layer (bao-agent, session isolation) | Planned |
| 8 | OpenBao MCP server (native agent tool integration) | Planned |
| 9 | High availability (multi-node Raft cluster) | Future |
| 10 | Open-source and community (docs, examples, contribution guide) | Active |

---

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                   Tailscale Tailnet                  │
│                                                     │
│  ┌──────────┐  ┌──────────┐  ┌───────────────────┐ │
│  │ Dev      │  │ Homelab  │  │ Cloud Agents      │ │
│  │ Machine  │  │ K8s Nodes│  │ (CI, Lambda, etc.)│ │
│  └────┬─────┘  └────┬─────┘  └────────┬──────────┘ │
│       │              │                 │            │
│       └──────────────┼─────────────────┘            │
│                      │                              │
│               ┌──────▼──────┐                       │
│               │ EC2 OpenBao │                       │
│               │  t4g.micro  │                       │
│               │ (Tailscale  │                       │
│               │  iface only)│                       │
│               └──────┬──────┘                       │
└──────────────────────┼──────────────────────────────┘
                       │ (internal AWS)
              ┌────────┼────────┐
              │        │        │
         ┌────▼───┐ ┌──▼──┐ ┌──▼────────┐
         │AWS KMS │ │ S3  │ │CloudWatch │
         │(unseal)│ │(bkp)│ │(alerting) │
         └────────┘ └─────┘ └───────────┘
```

## Repo Structure

> Directories marked **[EXISTS]** are built. Those marked **[PLANNED]** are defined here and will be created in the corresponding phase.

```
vault-stack/
├── terraform/                         # [EXISTS] — Phases 1-6
│   ├── main.tf              # EC2 instance, EBS, AMI data source
│   ├── iam.tf               # Instance profile, role, policies
│   ├── kms.tf               # Auto-unseal KMS key + key policy
│   ├── s3.tf                # Backup bucket, lifecycle, bucket policy
│   ├── networking.tf        # VPC/subnet selection, security group
│   ├── monitoring.tf        # CloudWatch alarms, SNS topic
│   ├── ssm.tf               # SSM session document + logging config
│   ├── variables.tf
│   ├── outputs.tf
│   ├── providers.tf         # AWS provider (region configurable via aws_region variable, default: ap-south-1)
│   ├── backend.tf           # Remote state config (S3 native locking)
│   └── terraform.tfvars     # gitignored
├── scripts/                           # [EXISTS] — Phases 2, 5
│   ├── user-data.sh         # Cloud-init: install OpenBao + Tailscale, start services
│   ├── init-openbao.sh      # One-time: bao operator init, store recovery keys
│   ├── backup.sh            # Raft snapshot → S3 (runs via cron)
│   ├── validate-init.sh     # Post-deployment validation checks
│   ├── restore.sh           # S3 → Raft snapshot restore (disaster recovery)
│   └── teardown-root.sh     # Revoke root token post-setup
├── config/                            # [EXISTS] — Phase 2
│   └── openbao.hcl          # OpenBao server configuration
├── bootstrap/                         # [EXISTS] — Phase 0
│   └── state.tf             # Terraform state bucket setup
├── policies/                          # [PLANNED] — Phase 4
│   ├── admin.hcl                    # Full admin policy (your user)
│   ├── templates/
│   │   ├── project-staging.hcl.tpl  # Template: project staging consumer
│   │   ├── project-prod.hcl.tpl    # Template: project prod consumer
│   │   ├── gha-staging.hcl.tpl     # Template: GitHub Actions staging
│   │   ├── gha-prod.hcl.tpl        # Template: GitHub Actions prod
│   │   ├── eks-app.hcl.tpl         # Template: EKS pod consumer
│   │   └── ecs-task.hcl.tpl        # Template: ECS task consumer
│   └── generated/                   # Auto-generated by onboard-project.sh (gitignored)
├── secrets-engines/                   # [PLANNED] — Phase 4
│   └── setup-engines.sh     # Enable KV v2, AWS secrets engine, Transit
├── onboarding/                        # [PLANNED] — Phase 4
│   ├── onboard-project.sh   # Read manifest → create policies + AppRoles + auth roles
│   ├── offboard-project.sh  # Remove project policies, AppRoles, and secrets
│   ├── validate-project.sh  # Check manifest ↔ OpenBao policy drift
│   └── list-projects.sh     # Show all onboarded projects and their consumers
├── consumers/                         # [PLANNED] — Phases 4, 7
│   ├── github-actions/
│   │   └── openbao-action-template.yml # Reusable GHA workflow snippet
│   ├── eks/
│   │   ├── openbao-injector-annotations.yaml # Reference annotations
│   │   ├── eso-secret-store.yaml            # External Secrets Operator config
│   │   └── setup-k8s-auth.sh               # Configure OpenBao K8s auth for a cluster
│   ├── ecs/
│   │   ├── entrypoint-openbao.sh    # Container entrypoint with OpenBao fetch
│   │   └── setup-aws-auth.sh        # Configure OpenBao AWS IAM auth
│   └── local-dev/
│       ├── session-launcher.sh      # Tmux session launcher with manifest reading
│       └── claude-code-vault.sh     # Simple Mode wrapper
├── openbao-agent/                     # [PLANNED] — Phase 7
│   ├── openbao-agent.hcl            # Agent config for local dev machines
│   ├── openbao-agent-k8s.hcl        # Agent config for K8s sidecar
│   ├── openbao-agent.service        # systemd unit file
│   ├── templates/
│   │   ├── agent-env.tpl            # Generic agent env template
│   │   └── aws-creds.tpl           # AWS credential_process template
│   └── install-openbao-agent.sh     # Setup script for dev machines
├── openbao-mcp-server/               # [PLANNED] — Phase 8
│   ├── package.json
│   ├── src/
│   │   ├── index.ts                 # MCP server entrypoint
│   │   ├── tools/
│   │   │   ├── read-secret.ts
│   │   │   ├── get-aws-creds.ts
│   │   │   ├── list-secrets.ts
│   │   │   └── encrypt-data.ts
│   │   ├── openbao-client.ts
│   │   ├── session.ts
│   │   ├── risk-gate.ts
│   │   └── lease-tracker.ts
│   └── README.md
├── manifest/                          # [PLANNED] — Phase 4
│   └── vault-manifest.schema.json   # JSON Schema for .vault-manifest.yaml validation
├── .gitignore               # tfvars, .terraform, state files, *.pem, policies/generated/
└── README.md                # Day-1 runbook, recovery procedures

# Root-level files (outside vault-stack/):
├── README.md                # Project overview and quick start
├── LICENSE                  # MPL-2.0
├── CONTRIBUTING.md          # Contribution guidelines
├── CLAUDE.md                # Claude Code project context
├── implementation-plan.md   # This document
├── examples/
│   ├── terraform.tfvars.example     # Variable template for deployment
│   ├── vault-manifest-simple.yaml   # Minimal project manifest example
│   └── vault-manifest-full.yaml     # Full multi-client manifest example
└── docs/
    ├── openbao-aws-handbook.md      # Architecture & operations handbook
    └── integration-patterns.md      # Auth patterns & integration reference
```

## Phase 0: Prerequisites

Complete these before touching any Terraform. Each item is a hard dependency — Phase 1 will fail without them.

### 0.1 Local Tooling

| Tool | Min Version | Check | Install |
|---|---|---|---|
| Terraform | >= 1.10 | `terraform version` | [developer.hashicorp.com/terraform/install](https://developer.hashicorp.com/terraform/install) |
| AWS CLI | v2 | `aws --version` | `brew install awscli` or [aws.amazon.com/cli](https://aws.amazon.com/cli/) |
| jq | any | `jq --version` | `brew install jq` |

### 0.2 AWS Account & Credentials

1. **AWS account** with admin access (or a role with permissions to create IAM, KMS, S3, EC2, CloudWatch, SNS, SSM resources)
2. **AWS credentials configured** locally:
   ```bash
   aws configure --profile vault-admin
   # or export AWS_PROFILE=vault-admin
   ```
3. **Verify access:**
   ```bash
   aws sts get-caller-identity
   # Should return your account ID and principal ARN
   ```
4. **Note your account ID** — needed for the backend.tf placeholder:
   ```bash
   aws sts get-caller-identity --query Account --output text
   ```

### 0.3 VPC & Networking (identify, don't create)

The Terraform config needs three IDs as input variables. Use the default VPC or an existing one:

```bash
# Default VPC
aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" \
  --query "Vpcs[0].VpcId" --output text

# Subnet (pick any in your target AZ)
aws ec2 describe-subnets --filters "Name=vpc-id,Values=<vpc-id>" \
  --query "Subnets[*].[SubnetId,AvailabilityZone]" --output table

# Route table (main route table for the VPC)
aws ec2 describe-route-tables --filters "Name=vpc-id,Values=<vpc-id>" \
  "Name=association.main,Values=true" \
  --query "RouteTables[0].RouteTableId" --output text
```

Record these for `terraform.tfvars`:
- `vpc_id`
- `subnet_id`
- `route_table_id`

### 0.4 Tailscale Auth Key

1. **Tailscale account** at [login.tailscale.com](https://login.tailscale.com)
2. **Generate an auth key** (Settings → Keys → Generate auth key):
   - Reusable: **no** (single-use for this instance)
   - Ephemeral: **yes** (node removed if it goes offline for 90+ days)
   - Pre-authorized tags: `tag:infra`
3. Save the key — you'll pass it as `tailscale_authkey` to Terraform (via env var, not tfvars file):
   ```bash
   export TF_VAR_tailscale_authkey="tskey-auth-..."
   ```

### 0.5 Bootstrap the Terraform State Bucket

**This must be done before `terraform init` on the main config.** The S3 state bucket is created by a standalone Terraform config in `bootstrap/`:

```bash
cd vault-stack/bootstrap
terraform init
terraform plan    # Review: should create KMS key, S3 bucket, bucket policy
terraform apply
```

After apply, note the bucket name (`vault-infra-tfstate-<account-id>`) and update `vault-stack/terraform/backend.tf`:

```bash
# Replace the placeholder in backend.tf with your actual account ID
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
sed -i '' "s/<account-id>/$ACCOUNT_ID/" ../terraform/backend.tf
```

**Verify the state bucket exists:**
```bash
aws s3 ls | grep vault-infra-tfstate
```

### 0.6 Prepare `terraform.tfvars`

Create `vault-stack/terraform/terraform.tfvars` (gitignored — never commit this):

```hcl
vpc_id         = "vpc-xxxxxxxxx"
subnet_id      = "subnet-xxxxxxxxx"
route_table_id = "rtb-xxxxxxxxx"
alert_email    = "you@example.com"

# Optional overrides (defaults are sensible):
# instance_type    = "t4g.small"
# openbao_version  = "2.1.0"
# admin_role_name  = "admin"
# aws_region       = "ap-south-1"
```

Pass the Tailscale auth key via environment variable (not in tfvars):
```bash
export TF_VAR_tailscale_authkey="tskey-auth-..."
```

### 0.7 Prerequisite Checklist

Run this before proceeding to Phase 1:

```bash
echo "=== Phase 0 Checklist ==="
echo -n "Terraform >= 1.10: "; terraform version -json | jq -r '.terraform_version'
echo -n "AWS CLI: "; aws --version 2>&1 | head -1
echo -n "AWS identity: "; aws sts get-caller-identity --query Arn --output text
echo -n "State bucket: "; aws s3 ls | grep vault-infra-tfstate | awk '{print $3}'
echo -n "VPC ID set: "; grep vpc_id terraform.tfvars 2>/dev/null || echo "MISSING"
echo -n "Tailscale key set: "; [ -n "${TF_VAR_tailscale_authkey:-}" ] && echo "yes" || echo "MISSING"
```

All items should resolve. If any show MISSING, fix before continuing.

---

## Phase 1: Terraform Foundation

### 1.1 Remote State Setup (manual, one-time)

> **Already done in Phase 0.5.** This section documents what the bootstrap created. If you followed Phase 0, skip to Phase 1.2.

Before anything else, create the state backend. This is a bootstrap step done manually or with a minimal separate Terraform config.

- S3 bucket for state: `vault-infra-tfstate-<account-id>`
- State locking: S3 native locking (Terraform 1.10+, `use_lockfile = true`). No DynamoDB table needed.
- Bucket policy: restrict to admin IAM role only
- Encryption: SSE-KMS with customer-managed key (state contains sensitive values)
- Versioning: enabled

> S3 encrypts all new objects with SSE-S3 by default (since January 2023). Customer-managed KMS keys add key rotation control and CloudTrail audit of key usage.

> **Provider requirements:** `hashicorp/aws ~> 5.0`, `hashicorp/random ~> 3.0`. Terraform `>= 1.10` (required for S3 native state locking).

**Complete `bootstrap/state.tf` (run once, manually):**

```hcl
# bootstrap/state.tf — creates the S3 bucket for Terraform state
# Run this standalone before the main Terraform config.
# After apply, configure the main backend to point here.

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "ap-south-1"
}

data "aws_caller_identity" "current" {}

# KMS key for state encryption
resource "aws_kms_key" "terraform_state" {
  description             = "Terraform state encryption"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = {
    Purpose   = "terraform-state-encryption"
    ManagedBy = "terraform-bootstrap"
  }
}

resource "aws_kms_alias" "terraform_state" {
  name          = "alias/terraform-state"
  target_key_id = aws_kms_key.terraform_state.id
}

# State bucket
resource "aws_s3_bucket" "terraform_state" {
  bucket = "vault-infra-tfstate-${data.aws_caller_identity.current.account_id}"

  tags = {
    Purpose   = "terraform-state"
    ManagedBy = "terraform-bootstrap"
  }
}

resource "aws_s3_bucket_versioning" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.terraform_state.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Bucket policy: deny unencrypted uploads and deny delete
resource "aws_s3_bucket_policy" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyUnencryptedUploads"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.terraform_state.arn}/*"
        Condition = {
          StringNotEquals = {
            "s3:x-amz-server-side-encryption" = "aws:kms"
          }
        }
      },
      {
        Sid       = "DenyDeleteOperations"
        Effect    = "Deny"
        Principal = "*"
        Action = [
          "s3:DeleteObject",
          "s3:DeleteObjectVersion",
          "s3:DeleteBucket"
        ]
        Resource = [
          aws_s3_bucket.terraform_state.arn,
          "${aws_s3_bucket.terraform_state.arn}/*"
        ]
      },
      {
        Sid       = "RestrictToAdminRole"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.terraform_state.arn,
          "${aws_s3_bucket.terraform_state.arn}/*"
        ]
        Condition = {
          StringNotEquals = {
            "aws:PrincipalArn" = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/admin"
          }
        }
      }
    ]
  })
}
```

**Main project `backend.tf`** (configured after bootstrap):

```hcl
terraform {
  backend "s3" {
    bucket       = "vault-infra-tfstate-<account-id>"
    key          = "vault/terraform.tfstate"
    region       = "ap-south-1"
    encrypt      = true
    kms_key_id   = "alias/terraform-state"
    use_lockfile = true  # S3 native locking (Terraform 1.10+), no DynamoDB needed
  }
}
```

> **State file sensitivity:** Terraform state contains resource attributes in plaintext, including KMS key ARNs, IAM role ARNs, security group IDs, and any values passed through `user_data`. Treat the state bucket with the same security posture as the OpenBao instance itself. The KMS encryption + bucket policy + versioning combination ensures state is encrypted at rest, access-controlled, and recoverable from accidental overwrites.

### 1.2 KMS Key (`kms.tf`)

- Create a symmetric KMS key for OpenBao auto-unseal
- Key policy conditions:
  - `kms:ViaService: ec2.ap-south-1.amazonaws.com` — restricts usage to EC2 context
  - `kms:CallerAccount` — restricts to your account
  - Grant `kms:Encrypt`, `kms:Decrypt`, `kms:DescribeKey` to the OpenBao instance role only
- Enable CloudTrail logging on this key (automatic if CloudTrail is enabled for management events)
- Tag: `Purpose: openbao-auto-unseal`
- Create a separate KMS key for S3 backup encryption (not the same key as unseal — separation of concerns)

**Key policy vs IAM policy — where to put conditions:**

KMS has two layers of access control: the **key policy** (attached to the key itself) and **IAM policies** (attached to users/roles). Both must allow an action for it to succeed. This means you can split concerns:

```hcl
# Key policy: controls WHO can use the key and via WHICH service
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
        Sid    = "AllowVaultUnseal"
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
            "kms:ViaService" = "ec2.ap-south-1.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = {
    Purpose   = "openbao-auto-unseal"
    ManagedBy = "terraform"
  }
}

resource "aws_kms_alias" "openbao_unseal" {
  name          = "alias/openbao-unseal"
  target_key_id = aws_kms_key.openbao_unseal.id
}
```

```hcl
# IAM policy on the instance role: grants the actions WITHOUT duplicating conditions
# The key policy's kms:ViaService condition already restricts to EC2 context
resource "aws_iam_role_policy" "vault_kms" {
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
```

> **Why split?** The key policy is the source of truth for "who can use this key under what conditions." The IAM policy is the source of truth for "what this role can do." Don't duplicate `kms:ViaService` in both — it creates maintenance burden and confusion about which layer is enforcing what. Put service-scoping conditions on the key policy, put resource-scoping (which key ARN) on the IAM policy.

### 1.3 S3 Backup Bucket (`s3.tf`)

- Bucket name: `openbao-raft-backups-<account-id>`
- Versioning: enabled
- MFA Delete: enabled (prevents backup destruction even with compromised IAM)
- Server-side encryption: SSE-KMS using the dedicated backup KMS key
- Block all public access (account-level + bucket-level)
- Lifecycle policy: transition to IA after 30 days, expire after 90 days
- Bucket policy: explicit deny for all principals except instance role (read/write) and admin role (read-only)
- No replication needed — single-region backups are acceptable for this scale

**Complete `s3.tf`:**

```hcl
# Dedicated KMS key for backup encryption (separate from unseal key)
resource "aws_kms_key" "vault_backup" {
  description             = "OpenBao Raft backup encryption"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = {
    Purpose   = "openbao-backup-encryption"
    ManagedBy = "terraform"
  }
}

resource "aws_kms_alias" "vault_backup" {
  name          = "alias/openbao-backup"
  target_key_id = aws_kms_key.openbao_backup.id
}

# Backup bucket
resource "aws_s3_bucket" "vault_backups" {
  bucket = "openbao-raft-backups-${data.aws_caller_identity.current.account_id}"

  tags = {
    Purpose   = "openbao-raft-backups"
    ManagedBy = "terraform"
  }
}

resource "aws_s3_bucket_versioning" "vault_backups" {
  bucket = aws_s3_bucket.openbao_backups.id

  versioning_configuration {
    status     = "Enabled"
    mfa_delete = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "vault_backups" {
  bucket = aws_s3_bucket.openbao_backups.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.openbao_backup.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "vault_backups" {
  bucket = aws_s3_bucket.openbao_backups.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "vault_backups" {
  bucket = aws_s3_bucket.openbao_backups.id

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
```

> **Lifecycle tiers:** Snapshots stay in Standard for 30 days (fast restore), move to IA at 30 days (cheaper, still quick access), Glacier at 60 days (disaster recovery only), and expire at 90 days. Noncurrent versions (from versioning) expire after 30 days to prevent unbounded storage growth.

### 1.4 IAM (`iam.tf`)

Instance profile with a role carrying two inline policies:

**KMS policy:**
```json
{
  "Effect": "Allow",
  "Action": ["kms:Encrypt", "kms:Decrypt", "kms:DescribeKey"],
  "Resource": "<unseal-kms-key-arn>",
  "Condition": {
    "StringEquals": {
      "kms:ViaService": "ec2.ap-south-1.amazonaws.com"
    }
  }
}
```

> **Hardening note:** The `kms:ViaService` condition alone allows any EC2 instance in the region to use this key. Pin to the OpenBao instance's IAM role ARN by adding:
> ```json
> "StringEquals": {
>   "kms:CallerAccount": "<account-id>",
>   "kms:ViaService": "ec2.ap-south-1.amazonaws.com"
> },
> "ArnEquals": {
>   "aws:PrincipalArn": "arn:aws:iam::<account-id>:role/openbao-instance-role"
> }
> ```
> After the OpenBao EC2 instance is created, further tighten by adding the instance ID as a condition.

**S3 backup policy:**
```json
{
  "Effect": "Allow",
  "Action": ["s3:PutObject", "s3:GetObject", "s3:ListBucket"],
  "Resource": [
    "arn:aws:s3:::openbao-raft-backups-<account-id>",
    "arn:aws:s3:::openbao-raft-backups-<account-id>/*"
  ]
}
```

**SSM policy** (for Session Manager access):
- Attach `AmazonSSMManagedInstanceCore` managed policy

> **Alternative:** Tailscale SSH (GA since 2024) provides identity-based SSH access without IAM/SSM — Tailscale handles authentication, authorization, and audit logging. Consider this for simpler access management. SSM remains useful for MFA enforcement and session recording to S3.

No other permissions. No `s3:DeleteObject` on the backup bucket from the instance role — backups are append-only from the instance's perspective.

**Bucket policy (explicit deny for unauthorized access):**

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyDeleteFromAll",
      "Effect": "Deny",
      "Principal": "*",
      "Action": ["s3:DeleteObject", "s3:DeleteBucket", "s3:PutBucketPolicy"],
      "Resource": [
        "arn:aws:s3:::openbao-raft-backups-<account-id>",
        "arn:aws:s3:::openbao-raft-backups-<account-id>/*"
      ]
    },
    {
      "Sid": "DenyUnauthorizedAccess",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:*",
      "Resource": [
        "arn:aws:s3:::openbao-raft-backups-<account-id>",
        "arn:aws:s3:::openbao-raft-backups-<account-id>/*"
      ],
      "Condition": {
        "StringNotEquals": {
          "aws:PrincipalArn": [
            "arn:aws:iam::<account-id>:role/openbao-instance-role",
            "arn:aws:iam::<account-id>:user/admin"
          ]
        }
      }
    }
  ]
}
```

Enable MFA Delete on the bucket for additional protection against backup tampering.

### 1.5 Networking (`networking.tf`)

- Use default VPC or a dedicated VPC — keep it simple
- Security group:
  - Inbound: **nothing**. Zero open ports. OpenBao is accessed via Tailscale, SSH via SSM. No public exposure.
  - Outbound: allow HTTPS (443) for AWS API calls (KMS, S3, SSM, Tailscale coordination), allow UDP 41641 for Tailscale direct connections

- No elastic IP needed — Tailscale provides stable addressing via MagicDNS
- EC2 instance in a private subnet if you have a NAT gateway, otherwise public subnet is fine since the SG has no inbound rules

**Security group resource:**

```hcl
resource "aws_security_group" "openbao" {
  name        = "openbao-instance"
  description = "OpenBao EC2 — no inbound, scoped outbound"
  vpc_id      = var.vpc_id

  # No ingress rules — OpenBao is accessed exclusively via Tailscale
  # Tailscale establishes outbound connections and receives replies via stateful tracking

  # HTTPS — AWS API calls (KMS, S3, SSM, STS, CloudWatch), Tailscale coordination
  egress {
    description = "HTTPS to AWS APIs and Tailscale coordination"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTP — package manager updates (apt), OpenBao releases
  egress {
    description = "HTTP for package updates"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # DNS (UDP) — required for all name resolution
  egress {
    description = "DNS UDP"
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # DNS (TCP) — fallback for large DNS responses
  egress {
    description = "DNS TCP"
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # NTP — time synchronization (critical for TLS, OpenBao leases, AWS SigV4)
  egress {
    description = "NTP"
    from_port   = 123
    to_port     = 123
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Tailscale WireGuard — direct peer connections
  egress {
    description = "Tailscale WireGuard"
    from_port   = 41641
    to_port     = 41641
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Tailscale STUN — NAT traversal for direct connections
  egress {
    description = "Tailscale STUN"
    from_port   = 3478
    to_port     = 3478
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name      = "openbao-instance"
    ManagedBy = "terraform"
  }
}
```

> **No inbound rules at all.** Tailscale works by establishing outbound WireGuard connections to the coordination server and peers. Return traffic flows back through the stateful connection tracking in the security group. This means the instance has zero attack surface from the network perspective — no port scanning, no brute force, no exploitation of listening services. OpenBao listens on the Tailscale interface (100.x.y.z:8200), which is only reachable by authenticated tailnet members.

**VPC Endpoints (optional, for private subnet deployments):**

The S3 Gateway endpoint is free and keeps S3 traffic within the AWS network. Add it regardless of subnet type:

```hcl
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.ap-south-1.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [var.route_table_id]

  tags = {
    Name      = "openbao-s3-endpoint"
    ManagedBy = "terraform"
  }
}
```

> **Interface endpoints (KMS, SSM, CloudWatch)** cost ~$7.20/month each ($14.40+ total). Defer these unless you move to a private subnet with no internet gateway. Without them, KMS/SSM/CloudWatch API calls route through the internet gateway, which is acceptable for a Tailscale-only instance with no inbound rules.


### 1.6 EC2 Instance (`main.tf`)

- AMI: latest Ubuntu 24.04 LTS arm64 (use `aws_ami` data source)
- Instance type: `t4g.micro`

> **Sizing consideration:** t4g.micro (1 vCPU, 1GB RAM) is marginal for OpenBao + Raft + audit logging under load. If burst credits deplete, CPU throttles to 5% baseline, causing latency spikes. Consider t4g.small (2 vCPU, 2GB RAM, ~$13/mo) for stability. Add a CloudWatch alarm for `CPUCreditBalance < 20` to detect credit exhaustion before it impacts agents.

- EBS: 30GB gp3, encrypted with default EBS encryption key
- IMDSv2 enforced: `http_tokens = "required"` — non-negotiable
- `user_data`: points to `scripts/user-data.sh`
- Instance profile: attached
- Tags: `Name: openbao`, `ManagedBy: terraform`
- Monitoring: detailed monitoring enabled (1-minute CloudWatch metrics)

**EC2 instance resource:**

```hcl
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

resource "aws_instance" "openbao" {
  ami                  = data.aws_ami.ubuntu.id
  instance_type        = var.instance_type # "t4g.micro" or "t4g.small"
  iam_instance_profile = aws_iam_instance_profile.openbao.name
  monitoring           = true # Detailed monitoring (1-min metrics)

  vpc_security_group_ids = [aws_security_group.openbao.id]
  subnet_id              = var.subnet_id

  root_block_device {
    volume_size           = 30
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
    tags                  = { Name = "openbao-root", ManagedBy = "terraform" }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 enforced
    http_put_response_hop_limit = 1          # Prevent container/proxy SSRF
    instance_metadata_tags      = "disabled"
  }

  user_data_base64 = base64encode(templatefile("${path.module}/../scripts/user-data.sh", {
    openbao_version  = var.openbao_version
    kms_key_id       = aws_kms_key.openbao_unseal.id
    tailscale_authkey = var.tailscale_authkey
    backup_bucket    = aws_s3_bucket.openbao_backups.id
    backup_kms_key   = aws_kms_key.openbao_backup.arn
  }))

  tags = {
    Name      = "openbao"
    ManagedBy = "terraform"
  }

  lifecycle {
    ignore_changes = [ami, user_data_base64]
  }
}
```

> **IMDSv2 enforcement (`http_tokens = "required"`):** This prevents SSRF attacks from extracting instance credentials via the metadata service. Without IMDSv2, any process on the instance (or any SSRF vulnerability in OpenBao/Tailscale) can `curl http://169.254.169.254/latest/meta-data/iam/security-credentials/` and get the instance role's temporary credentials. IMDSv2 requires a PUT request to get a session token first, which SSRF payloads typically cannot do. The `hop_limit = 1` further restricts metadata access to the instance itself, preventing forwarded requests from reaching IMDS.

### 1.7 Monitoring (`monitoring.tf`)

- SNS topic for alerts (email subscription to your address)
- CloudWatch alarm: `StatusCheckFailed` > 0 for 2 consecutive periods → SNS
- CloudWatch alarm: `CPUUtilization` > 90% sustained 10 min → SNS (indicates something wrong)
- Optional: CloudWatch log group for OpenBao audit logs shipped via CloudWatch agent
- CloudTrail: ensure management events are being logged (KMS usage will appear here)

**Complete `monitoring.tf`:**

```hcl
# SNS topic for OpenBao alerts
resource "aws_sns_topic" "openbao_alerts" {
  name = "openbao-alerts"
  tags = { ManagedBy = "terraform" }
}

resource "aws_sns_topic_subscription" "vault_alerts_email" {
  topic_arn = aws_sns_topic.openbao_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# Alarm 1: Instance status check
resource "aws_cloudwatch_metric_alarm" "status_check" {
  alarm_name          = "openbao-status-check-failed"
  alarm_description   = "OpenBao EC2 instance failed status check"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  dimensions          = { InstanceId = aws_instance.openbao.id }
  alarm_actions       = [aws_sns_topic.openbao_alerts.arn]
  ok_actions          = [aws_sns_topic.openbao_alerts.arn]
}

# Alarm 2: CPU sustained high
resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "openbao-cpu-high"
  alarm_description   = "OpenBao CPU above 90% for 10 minutes"
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = 90
  comparison_operator = "GreaterThanThreshold"
  dimensions          = { InstanceId = aws_instance.openbao.id }
  alarm_actions       = [aws_sns_topic.openbao_alerts.arn]
}

# Alarm 3: CPU credit balance low (t4g burst credits)
resource "aws_cloudwatch_metric_alarm" "cpu_credits_low" {
  alarm_name          = "openbao-cpu-credits-low"
  alarm_description   = "OpenBao CPU credit balance below 20 — throttling imminent"
  namespace           = "AWS/EC2"
  metric_name         = "CPUCreditBalance"
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 2
  threshold           = 20
  comparison_operator = "LessThanThreshold"
  dimensions          = { InstanceId = aws_instance.openbao.id }
  alarm_actions       = [aws_sns_topic.openbao_alerts.arn]
}

# Alarm 4: Disk usage high (requires CloudWatch agent custom metric)
resource "aws_cloudwatch_metric_alarm" "disk_high" {
  alarm_name          = "openbao-disk-usage-high"
  alarm_description   = "OpenBao disk usage above 80%"
  namespace           = "OpenBao"
  metric_name         = "disk_used_percent"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  dimensions = {
    InstanceId = aws_instance.openbao.id
    path       = "/"
  }
  alarm_actions = [aws_sns_topic.openbao_alerts.arn]
}

# Alarm 5: Memory usage high (requires CloudWatch agent custom metric)
resource "aws_cloudwatch_metric_alarm" "memory_high" {
  alarm_name          = "openbao-memory-high"
  alarm_description   = "OpenBao memory usage above 85%"
  namespace           = "OpenBao"
  metric_name         = "mem_used_percent"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  threshold           = 85
  comparison_operator = "GreaterThanThreshold"
  dimensions          = { InstanceId = aws_instance.openbao.id }
  alarm_actions       = [aws_sns_topic.openbao_alerts.arn]
}

# Alarm 6: KMS errors (tracks failed unseal/encrypt operations)
resource "aws_cloudwatch_metric_alarm" "kms_errors" {
  alarm_name          = "openbao-kms-errors"
  alarm_description   = "KMS decrypt errors — OpenBao may fail to unseal on restart"
  namespace           = "AWS/KMS"
  metric_name         = "KMSKeyError"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.openbao_alerts.arn]
}

# CloudWatch log group for OpenBao audit logs
resource "aws_cloudwatch_log_group" "openbao_audit" {
  name              = "/openbao/audit"
  retention_in_days = 90
  tags              = { ManagedBy = "terraform" }
}

resource "aws_cloudwatch_log_group" "openbao_system" {
  name              = "/openbao/system"
  retention_in_days = 30
  tags              = { ManagedBy = "terraform" }
}
```

> **Alarms 4 and 5** (disk and memory) require the CloudWatch agent to be installed and publishing custom metrics to the `OpenBao` namespace. These alarms will stay in `INSUFFICIENT_DATA` state until the agent is configured in Phase 4.1.

### 1.8 SSM Configuration (`ssm.tf`)

- SSM Session Document: restrict to specific IAM role ARN
- Session logging: log to S3 bucket or CloudWatch Logs
- Require MFA for IAM principals that can call `ssm:StartSession` (enforce via IAM policy condition `aws:MultiFactorAuthPresent`)

**SSM MFA enforcement IAM policy:**

```hcl
resource "aws_iam_policy" "ssm_mfa_required" {
  name        = "openbao-ssm-mfa-required"
  description = "Allows SSM StartSession only with MFA"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowSSMWithMFA"
        Effect = "Allow"
        Action = [
          "ssm:StartSession",
          "ssm:TerminateSession",
          "ssm:ResumeSession"
        ]
        Resource = [
          "arn:aws:ec2:ap-south-1:${data.aws_caller_identity.current.account_id}:instance/*",
          "arn:aws:ssm:ap-south-1:${data.aws_caller_identity.current.account_id}:document/SSM-SessionManagerRunShell"
        ]
        Condition = {
          Bool = {
            "aws:MultiFactorAuthPresent" = "true"
          }
          NumericLessThan = {
            "aws:MultiFactorAuthAge" = "3600"
          }
        }
      },
      {
        Sid    = "DenySSMWithoutMFA"
        Effect = "Deny"
        Action = [
          "ssm:StartSession"
        ]
        Resource = "*"
        Condition = {
          BoolIfExists = {
            "aws:MultiFactorAuthPresent" = "false"
          }
        }
      }
    ]
  })
}
```

> **Session recording:** Enable SSM session logging to S3 to maintain an audit trail of all interactive sessions. This complements OpenBao audit logs by capturing what operators did on the instance, not just what they read from OpenBao.

---

## Phase 2: Instance Provisioning

### 2.1 user-data.sh (cloud-init)

The script runs on first boot and does the following in order:

1. System updates: `apt update && apt upgrade -y`, enable `unattended-upgrades`
2. Install OpenBao:
   - **Do not use `apt install` for production** — it pulls non-deterministic versions
   - Download the pinned binary with checksum verification:

> **Version pinning (required for production):**
> ```bash
> OPENBAO_VERSION="2.1.0"  # Pin in Terraform variable — check github.com/openbao/openbao/releases for latest
> curl -fsSL "https://github.com/openbao/openbao/releases/download/v${OPENBAO_VERSION}/bao_${OPENBAO_VERSION}_linux_arm64.zip" \
>   -o /tmp/bao.zip
> unzip /tmp/bao.zip -d /usr/local/bin
> chmod 755 /usr/local/bin/bao
> ```

> **Production hardening for user-data.sh:**
>
> - **SHA256 verification:** Always verify the downloaded binary against the published checksums. Download `bao_${OPENBAO_VERSION}_SHA256SUMS`, then `sha256sum --check`. A corrupted or tampered binary is worse than no OpenBao at all.
> - **Structured logging:** Redirect all user-data output to both syslog and a dedicated log file: `exec > >(tee /var/log/user-data.log | logger -t user-data) 2>&1`. This makes cloud-init debugging possible after the fact.
> - **Tailscale timeout:** `tailscale up` can hang if the coordination server is unreachable. Add `--timeout=60s` and fail the script if Tailscale doesn't connect. An OpenBao instance without Tailscale is unreachable and useless.
> - **Health check polling:** After `systemctl start openbao`, poll the health endpoint before declaring success: `for i in $(seq 1 30); do curl -sf http://127.0.0.1:8200/v1/sys/health && break; sleep 2; done`. This catches systemd start failures that would otherwise go unnoticed until you try to init.
> - **systemd hardening:** Add these directives to the OpenBao systemd unit for defense in depth:
>   ```ini
>   ProtectSystem=full
>   ProtectHome=true
>   PrivateTmp=true
>   NoNewPrivileges=true
>   CapabilityBoundingSet=CAP_IPC_LOCK CAP_NET_BIND_SERVICE
>   AmbientCapabilities=CAP_IPC_LOCK
>   ```
>   These prevent the OpenBao process from modifying system files, accessing home directories, or gaining new privileges even if compromised.

3. Install Tailscale:
   - Add Tailscale apt repo
   - `apt install tailscale`
   - `tailscale up --authkey=<key> --hostname=openbao --advertise-tags=tag:infra`
   - Auth key sourced from a Terraform variable (passed via user_data template), ephemeral + single-use
4. Configure OpenBao:
   - Write `openbao.hcl` to `/etc/openbao/openbao.hcl`
   - Create data directory: `/opt/openbao/data`, owned by `openbao` user
   - The Tailscale IP is not known at Terraform plan time — the user-data script grabs it dynamically: `tailscale ip -4` after Tailscale is up, then templates it into openbao.hcl
5. Start OpenBao:
   - `systemctl enable openbao && systemctl start openbao`
6. Install CloudWatch agent (optional, for audit log shipping)
7. Set up cron for backups:
   - Copy `backup.sh` and schedule via cron: `0 */6 * * *` (every 6 hours)

### 2.2 openbao.hcl

```hcl
ui = true

listener "tcp" {
  address     = "<tailscale-ip>:8200"
  tls_disable = true  # Tailscale WireGuard handles encryption
}

storage "raft" {
  path    = "/opt/openbao/data"
  node_id = "openbao-1"
}

seal "awskms" {
  region     = "ap-south-1"
  kms_key_id = "<kms-key-id>"  # Templated by user-data
}

api_addr     = "http://<tailscale-ip>:8200"
cluster_addr = "http://<tailscale-ip>:8201"

telemetry {
  disable_hostname = true
  prometheus_retention_time = "12h"
}
```

### 2.3 OpenBao Initialization (manual, one-time)

After first boot:

1. SSM into the instance
2. `export BAO_ADDR=http://<tailscale-ip>:8200`
3. `bao operator init -recovery-shares=5 -recovery-threshold=3`
   - With KMS auto-unseal, these are "recovery keys" not "unseal keys"
   - OpenBao auto-unseals via KMS — recovery keys are for emergency operations only
4. Save recovery keys: split across locations
   - Share 1: 1Password vault
   - Share 2: Bitwarden vault (different service)
   - Share 3: Printed, physically stored
   - Shares 4-5: additional secure locations of your choice
   - 3-of-5 threshold means no single point of compromise
5. Save initial root token temporarily
6. Authenticate with root token, create your admin user/policy, then run `teardown-root.sh` to revoke the root token

### 2.4 teardown-root.sh

```bash
#!/bin/bash
bao token revoke -self
echo "Root token revoked. Generate a new one with: bao operator generate-root"
```

### 2.5 Post-Init Validation (`validate-init.sh`)

Run after init + teardown-root to verify the deployment is correctly configured:

```bash
#!/bin/bash
# validate-init.sh — post-init validation checks
set -euo pipefail

BAO_ADDR="${BAO_ADDR:-http://$(tailscale ip -4):8200}"
export BAO_ADDR

PASS=0
FAIL=0

check() {
  local description="$1"
  shift
  if "$@" > /dev/null 2>&1; then
    echo "  [PASS] $description"
    ((PASS++))
  else
    echo "  [FAIL] $description"
    ((FAIL++))
  fi
}

echo "=== OpenBao Post-Init Validation ==="
echo ""

# 1. OpenBao status
echo "--- Core Status ---"
check "OpenBao is running and responding" bao status -format=json
check "OpenBao is unsealed" bash -c 'bao status -format=json | jq -e ".sealed == false"'
check "Seal type is awskms" bash -c 'bao status -format=json | jq -e ".seal_type == \"awskms\""'
check "Raft storage is initialized" bash -c 'bao status -format=json | jq -e ".initialized == true"'

# 2. Raft cluster
echo ""
echo "--- Raft Storage ---"
check "Raft peer list is non-empty" bash -c 'bao operator raft list-peers -format=json | jq -e ".data.config.servers | length > 0"'

# 3. Auth methods
echo ""
echo "--- Auth Methods ---"
check "Token auth is enabled" bash -c 'bao auth list -format=json | jq -e ".\"token/\""'

# 4. Secrets engines
echo ""
echo "--- Secrets Engines ---"
check "System backend is accessible" bao secrets list -format=json

# 5. Audit devices
echo ""
echo "--- Audit ---"
check "At least one audit device is enabled" bash -c 'bao audit list -format=json | jq -e "length > 0"'
check "File audit device exists" bash -c 'bao audit list -format=json | jq -e ".[\"file/\"]"'

# 6. AWS connectivity
echo ""
echo "--- AWS Connectivity ---"
check "S3 backup bucket is reachable" aws s3 ls "s3://openbao-raft-backups-$(aws sts get-caller-identity --query Account --output text)" --max-items 1
check "KMS key is accessible" aws kms describe-key --key-id "$(bao status -format=json | jq -r '.seal_details.kms_key_id // empty')" --region ap-south-1

# 7. Tailscale
echo ""
echo "--- Tailscale ---"
check "Tailscale is running" tailscale status
check "OpenBao is listening on Tailscale IP" bash -c 'curl -sf "http://$(tailscale ip -4):8200/v1/sys/health" | jq -e ".initialized == true"'

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="

if [ "$FAIL" -gt 0 ]; then
  echo "WARNING: Some checks failed. Review before proceeding."
  exit 1
fi
```

> Run this script after Phase 2.3 init and Phase 2.4 root token teardown. It validates that the deployment is functional before proceeding to Phase 3+ configuration.

---

## Phase 3: Tailscale Network Hardening

### 3.1 Tailscale ACL Policy

Add to your Tailscale ACL (admin console or gitops'd policy file):

```json
{
  "acls": [
    {
      "action": "accept",
      "src": ["tag:agent", "tag:dev"],
      "dst": ["tag:infra:8200"]
    },
    {
      "action": "accept",
      "src": ["tag:dev"],
      "dst": ["tag:infra:22"]
    }
  ],
  "tagOwners": {
    "tag:infra":  ["autogroup:admin"],
    "tag:agent":  ["autogroup:admin"],
    "tag:dev":    ["autogroup:admin"]
  }
}
```

- `tag:infra` — the OpenBao EC2 instance
- `tag:agent` — homelab nodes, CI runners, any machine running agentic workflows
- `tag:dev` — your personal machines
- Only `tag:agent` and `tag:dev` can reach OpenBao on port 8200
- Only `tag:dev` can SSH (port 22) for emergency access
- All other tailnet devices are denied by default

### 3.2 Tailscale Auth Key Management

- Generate ephemeral, single-use, tagged auth key for EC2 provisioning
- Key should pre-authorize the `tag:infra` tag
- Never store the auth key in Terraform state — pass it via environment variable to `terraform apply` and it flows into user_data
- After the instance joins the tailnet, the auth key is consumed and useless

### 3.3 Device Approval

- Enable device approval in Tailscale admin settings
- New devices joining the tailnet require manual approval
- Prevents a leaked auth key from silently adding rogue nodes

---

## Phase 4: OpenBao Configuration

### 4.1 Enable Audit Logging

First thing after init, before any other configuration:

```bash
bao audit enable file file_path=/var/log/openbao/audit.log
```

Every secret access, authentication, and policy check is now logged with accessor identity, timestamp, and request details. Ship to SigNoz via the OpenTelemetry collector or CloudWatch agent.

### Audit Log Management

**Log rotation (add to instance provisioning):**

```
# /etc/logrotate.d/openbao
/var/log/openbao/audit.log {
    daily
    rotate 30
    compress
    missingok
    notifempty
    copytruncate
    postrotate
        systemctl reload openbao >/dev/null 2>&1 || true
    endscript
}
```

**Log shipping (mandatory, not optional):**

Ship audit logs to S3 for immutable retention. Use the CloudWatch agent to forward logs, then configure a CloudWatch Logs subscription to push to S3 with Object Lock (governance mode, 90-day retention). This ensures audit logs cannot be deleted even if the EC2 instance is compromised.


**Retention policy:** 30 days on local disk (logrotate), 90 days in S3 (Object Lock), indefinite in log aggregator (SigNoz/CloudWatch) for querying.

**CloudWatch agent configuration (`/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json`):**

```json
{
  "agent": {
    "metrics_collection_interval": 60,
    "logfile": "/opt/aws/amazon-cloudwatch-agent/logs/amazon-cloudwatch-agent.log"
  },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/openbao/audit.log",
            "log_group_name": "/openbao/audit",
            "log_stream_name": "{instance_id}",
            "retention_in_days": 90,
            "timezone": "UTC"
          },
          {
            "file_path": "/var/log/syslog",
            "log_group_name": "/openbao/system",
            "log_stream_name": "{instance_id}",
            "retention_in_days": 30,
            "timezone": "UTC"
          }
        ]
      }
    }
  },
  "metrics": {
    "namespace": "OpenBao",
    "metrics_collected": {
      "disk": {
        "measurement": ["used_percent"],
        "resources": ["/", "/opt/openbao/data"],
        "metrics_collection_interval": 300
      },
      "mem": {
        "measurement": ["mem_used_percent"],
        "metrics_collection_interval": 300
      },
      "swap": {
        "measurement": ["swap_used_percent"],
        "metrics_collection_interval": 300
      }
    },
    "append_dimensions": {
      "InstanceId": "${aws:InstanceId}"
    }
  }
}
```

**Start the CloudWatch agent:**

```bash
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config \
  -m ec2 \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json \
  -s
```

> **IAM requirement:** The EC2 instance role needs the `CloudWatchAgentServerPolicy` managed policy attached. Add this to `iam.tf` alongside the existing KMS and S3 policies.

### 4.2 KV Hierarchy Design

The path structure is the organizational backbone. Every secret lives at a path that encodes which project, which environment, and what the secret is. This structure is not arbitrary — it maps directly to how policies, AppRoles, and consumers are scoped.

```
secret/
├── projects/                          # Per-project secrets
│   ├── works-on-my-cloud/            # Your agency site
│   │   ├── staging/
│   │   │   ├── database-url
│   │   │   ├── stripe-key
│   │   │   ├── resend-api-key
│   │   │   └── cloudflare-token
│   │   └── prod/
│   │       ├── database-url
│   │       ├── stripe-key
│   │       ├── resend-api-key
│   │       └── cloudflare-token
│   │
│   ├── clientA-platform/
│   │   ├── staging/
│   │   │   ├── database-url
│   │   │   ├── redis-url
│   │   │   ├── aws-account-id
│   │   │   └── openai-api-key
│   │   └── prod/
│   │       ├── database-url
│   │       ├── redis-url
│   │       ├── aws-account-id
│   │       └── openai-api-key
│   │
│   └── homelab-doctor/
│       └── staging/
│           ├── bedrock-region
│           └── signoz-endpoint
│
├── shared/                            # Cross-project secrets
│   ├── github-token                   # GitHub PAT
│   ├── npm-token                      # npm publish token
│   ├── dockerhub-creds               # Registry creds
│   └── tailscale-api-key
│
└── infra/                             # Infrastructure-level secrets
    ├── homelab/
    │   ├── argocd-admin
    │   ├── grafana-admin
    │   └── signoz-token
    └── aws/
        ├── route53-zone-id
        └── ecr-registry-url
```

**Design rules:**

- Path format is always `secret/<scope>/<project>/<environment>/<secret-name>`
- Staging and prod are always separate paths — same key name, different values, different policies
- `shared/` is for secrets used across multiple projects (GitHub PAT, Docker registry, npm)
- `infra/` is for infrastructure-layer secrets not tied to any single project
- Every secret is a single KV entry with a `value` field: `bao kv put secret/projects/X/staging/database-url value="postgresql://..."`
- KV v2 versioning is enabled — accidental overwrites are recoverable

**Storing secrets:**

```bash
# Project secrets — one command per secret, one time
bao kv put secret/projects/clientA-platform/staging/database-url \
  value="postgresql://app:staging-pass@staging-db.clientA.com:5432/platform"

bao kv put secret/projects/clientA-platform/prod/database-url \
  value="postgresql://app:prod-pass@prod-db.clientA.com:5432/platform"

# Shared secrets
bao kv put secret/shared/github-token value="ghp_xxxxxxxxxxxx"

# Infra secrets
bao kv put secret/infra/homelab/argocd-admin value="admin-password-here"
```

Rotating a secret is the same command — KV v2 creates a new version. Every consumer fetches the latest version on next access. One `bao kv put`, zero downstream config changes.

### 4.3 Auth Methods

Every consumer of OpenBao secrets authenticates using a method appropriate to its runtime environment. Five auth methods cover all use cases.

**AppRole** — for agents, local dev, and CI/CD:

AppRole is the primary method for anything that isn't running in Kubernetes or ECS. Each consumer gets its own AppRole bound to a specific policy. The `role_id` identifies the consumer, the `secret_id` proves identity.


```bash
# Per-project, per-environment, per-consumer AppRoles
bao auth enable approle

# Local dev / Claude Code — staging access
bao write auth/approle/role/dev-clientA-staging \
  token_ttl=2h \
  token_max_ttl=4h \
  secret_id_ttl=24h \
  secret_id_num_uses=10 \
  token_policies="clientA-staging-dev"

# GitHub Actions — staging deploy
bao write auth/approle/role/gha-clientA-staging \
  token_ttl=30m \
  token_max_ttl=1h \
  secret_id_ttl=0 \
  token_policies="clientA-staging-gha"

# GitHub Actions — prod deploy (shorter TTL, tighter controls)
bao write auth/approle/role/gha-clientA-prod \
  token_ttl=15m \
  token_max_ttl=30m \
  secret_id_ttl=0 \
  token_policies="clientA-prod-gha"
```

**Kubernetes Auth** — for EKS and homelab cluster pods:

Pods authenticate using their Kubernetes service account token. No secrets to inject — the pod's identity IS the credential.


```bash
# Enable K8s auth for EKS cluster
bao auth enable -path=kubernetes-eks kubernetes

bao write auth/kubernetes-eks/config \
  kubernetes_host="https://<eks-cluster-endpoint>" \
  kubernetes_ca_cert=@/tmp/eks-ca.crt

# Map a K8s service account to an OpenBao policy
bao write auth/kubernetes-eks/role/clientA-staging-app \
  bound_service_account_names="clientA-app" \
  bound_service_account_namespaces="clientA-staging" \
  policies="clientA-staging-eks" \
  ttl=1h

# Enable K8s auth for homelab Talos cluster
bao auth enable -path=kubernetes-homelab kubernetes

bao write auth/kubernetes-homelab/config \
  kubernetes_host="https://<talos-cluster-endpoint>" \
  kubernetes_ca_cert=@/tmp/talos-ca.crt

bao write auth/kubernetes-homelab/role/n8n-workflow \
  bound_service_account_names="n8n" \
  bound_service_account_namespaces="automation" \
  policies="homelab-n8n" \
  ttl=1h
```

> **Networking requirement:** OpenBao must be able to reach the Kubernetes API server to validate service account tokens. For EKS: the OpenBao EC2 instance must be in the same VPC (or have VPC peering) with security group rules allowing HTTPS to the EKS API endpoint. For homelab Talos cluster on Tailscale: the Talos API server must be reachable via MagicDNS from the OpenBao EC2 instance. Verify connectivity: `curl -k https://<k8s-api-endpoint>/healthz` from the OpenBao host.

> **EKS 1.28+ alternative:** AWS Pod Identity is a lighter alternative to IRSA + OpenBao K8s auth for EKS-native workloads. It reduces operational overhead but doesn't replace OpenBao for secret management — it's an auth method alternative.

**AWS IAM Auth** — for ECS tasks and Lambda functions:

ECS tasks and Lambda functions authenticate using their IAM execution role. No secrets to manage — the task's IAM role IS the credential.


```bash
# Enable AWS auth
bao auth enable aws

# Map an ECS task role to an OpenBao policy
bao write auth/aws/role/clientA-staging-ecs \
  auth_type=iam \
  bound_iam_principal_arn="arn:aws:iam::<account-id>:role/clientA-staging-task-role" \
  policies="clientA-staging-ecs" \
  ttl=1h

# Map a Lambda execution role
bao write auth/aws/role/clientA-staging-lambda \
  auth_type=iam \
  bound_iam_principal_arn="arn:aws:iam::<account-id>:role/clientA-staging-lambda-role" \
  policies="clientA-staging-lambda" \
  ttl=15m
```

**Userpass** — for your admin access:

```bash
bao auth enable userpass
bao write auth/userpass/users/chinmay \
  password="<strong-password>" \
  policies="admin"
```

Use this instead of root token for day-to-day management. Root token is revoked after initial setup.

**Token Auth** — for quick local dev/testing only:

```bash
bao token create -policy=clientA-staging-dev -ttl=2h -use-limit=50
```

Acceptable for actively supervised sessions. Not for unattended or production workflows.

### 4.4 Secrets Engines

**KV v2** at `secret/`:

```bash
bao secrets enable -version=2 -path=secret kv
```

For all static secrets: API keys, database passwords, third-party tokens. Versioned — accidental overwrites are recoverable via `bao kv rollback`.

**AWS Secrets Engine** at `aws/`:

```bash
bao secrets enable aws

bao write aws/config/root \
  access_key=AKIA... \
  secret_key=... \
  region=ap-south-1
```

Define roles per project-environment with locked-down IAM policy documents. Agents and CI request ephemeral STS credentials that auto-expire:


```bash
# Staging deploy role — allows common infra operations, denies dangerous actions
bao write aws/roles/clientA-staging-deploy \
  credential_type=iam_user \
  default_sts_ttl=1h \
  max_sts_ttl=4h \
  policy_document=-<<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:RunInstances", "ec2:DescribeInstances", "ec2:TerminateInstances",
        "s3:CreateBucket", "s3:PutObject", "s3:GetObject",
        "ecs:UpdateService", "ecs:DescribeServices",
        "ecr:GetAuthorizationToken", "ecr:BatchGetImage"
      ],
      "Resource": "*",
      "Condition": {
        "StringEquals": { "aws:RequestedRegion": "ap-south-1" }
      }
    },
    {
      "Effect": "Deny",
      "Action": [
        "s3:PutBucketPolicy", "s3:PutBucketAcl", "s3:PutObjectAcl",
        "ec2:AuthorizeSecurityGroupIngress",
        "iam:CreateUser", "iam:CreateAccessKey",
        "iam:AttachUserPolicy", "iam:AttachRolePolicy",
        "organizations:*", "account:*"
      ],
      "Resource": "*"
    }
  ]
}
EOF

# Prod deploy role — even tighter, specific resource ARNs
bao write aws/roles/clientA-prod-deploy \
  credential_type=iam_user \
  default_sts_ttl=30m \
  max_sts_ttl=1h \
  policy_document=-<<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["ecs:UpdateService", "ecs:DescribeServices", "ecr:GetAuthorizationToken"],
      "Resource": "arn:aws:ecs:ap-south-1:<account-id>:service/clientA-prod/*"
    },
    {
      "Effect": "Deny",
      "Action": ["iam:*", "organizations:*", "account:*", "s3:PutBucketPolicy"],
      "Resource": "*"
    }
  ]
}
EOF
```

**Transit** at `transit/` (optional):

```bash
bao secrets enable transit
bao write transit/keys/agent-data type=aes256-gcm96
```

Encryption-as-a-service for agents that need to encrypt data without managing keys.

### 4.5 Policies

Every policy is explicit-allow, deny-by-default. Policies are scoped to the intersection of project, environment, and consumer type. No wildcards on environment boundaries — a staging policy never grants access to prod paths.

**Policy naming convention:** `<project>-<environment>-<consumer>`

```hcl
# policies/generated/clientA-staging-dev.hcl
# Consumer: local dev / Claude Code for clientA staging

# Project-specific staging secrets
path "secret/data/projects/clientA-platform/staging/*" {
  capabilities = ["read"]
}

# Shared secrets (GitHub token, Docker registry)
path "secret/data/shared/*" {
  capabilities = ["read"]
}

# Dynamic AWS creds for staging
path "aws/creds/clientA-staging-deploy" {
  capabilities = ["read"]
}
```

```hcl
# policies/generated/clientA-staging-gha.hcl
# Consumer: GitHub Actions staging deploy

path "secret/data/projects/clientA-platform/staging/*" {
  capabilities = ["read"]
}

path "secret/data/shared/dockerhub-creds" {
  capabilities = ["read"]
}

path "aws/creds/clientA-staging-deploy" {
  capabilities = ["read"]
}

# No access to shared/github-token — GHA has its own
# No access to prod paths — separate AppRole for prod
```

```hcl
# policies/generated/clientA-prod-gha.hcl
# Consumer: GitHub Actions prod deploy

path "secret/data/projects/clientA-platform/prod/*" {
  capabilities = ["read"]
}

path "secret/data/shared/dockerhub-creds" {
  capabilities = ["read"]
}

path "aws/creds/clientA-prod-deploy" {
  capabilities = ["read"]
}

# Cannot read staging secrets — complete environment isolation
```

```hcl
# policies/generated/clientA-staging-eks.hcl
# Consumer: EKS pods for clientA staging

path "secret/data/projects/clientA-platform/staging/database-url" {
  capabilities = ["read"]
}

path "secret/data/projects/clientA-platform/staging/redis-url" {
  capabilities = ["read"]
}

# EKS pods get only the specific secrets they need
# Not wildcard on staging/* — the app doesn't need the Stripe key
```

**Explicit path policies vs wildcards:**

For dev and CI consumers, `staging/*` wildcards are acceptable — these consumers may need any project secret during development or deployment. For runtime consumers (EKS pods, ECS tasks), use explicit paths — the running application needs exactly the secrets it was designed to use, not the entire project's staging secrets. This limits the blast radius if a running pod is compromised.

### 4.6 Networking for EKS/ECS Consumers

OpenBao runs on Tailscale with no public endpoint. EKS and ECS workloads need to reach it. Three approaches, in order of recommendation:

**Option A: VPC Peering (recommended for AWS-native workloads)**

If OpenBao's EC2 instance is in the same AWS account as EKS/ECS, peer the VPCs and route traffic internally. OpenBao listens on its private VPC IP in addition to the Tailscale interface.

```hcl
# Add to openbao.hcl — listen on both Tailscale and private VPC IP
listener "tcp" {
  address     = "<tailscale-ip>:8200"
  tls_disable = true
}

listener "tcp" {
  address     = "<private-vpc-ip>:8200"
  tls_disable = false
  tls_cert_file = "/opt/openbao/tls/cert.pem"
  tls_key_file  = "/opt/openbao/tls/key.pem"
}
```

The VPC listener requires TLS since traffic traverses the AWS network, not Tailscale's WireGuard tunnel.
 Use cert-manager or AWS ACM Private CA for cert issuance.

Security group addition: allow inbound 8200 from the EKS/ECS VPC CIDR only.

Terraform additions: VPC peering connection, route table entries, security group rule.

**Option B: Tailscale Subnet Router**

Run Tailscale as a DaemonSet in EKS or a sidecar in ECS. Pods/tasks access OpenBao via the Tailscale IP. Most secure — OpenBao remains fully private on Tailscale — but adds operational complexity (Tailscale auth keys for every node/task).

**Option C: OpenBao Agent Proxy in Cluster**

Run bao agent in proxy mode as a Kubernetes Service or ECS service. All pods/tasks talk to the local proxy, the proxy talks to OpenBao over Tailscale. Reduces the number of components that need direct OpenBao access. Good for clusters with many consuming services.

For the initial setup, start with Option A (VPC peering). It's the lowest-friction approach when everything is in the same AWS account. Move to Option C if you scale beyond 5-10 consuming services in a cluster.

### 4.7 The .vault-manifest.yaml Specification

Every project repository contains a `.vault-manifest.yaml` that declares exactly which secrets the project needs and which consumers require access. This is the single source of truth for project-level OpenBao configuration.

```yaml
# .vault-manifest.yaml — lives in the project repo root
project:
  name: "clientA-platform"              # Must match KV path under secret/projects/
  environments: ["staging", "prod"]

secrets:
  - name: "database-url"
    description: "PostgreSQL connection string"
    environments: ["staging", "prod"]    # Present in both environments
    consumers: ["dev", "gha", "eks"]     # Who needs this secret

  - name: "redis-url"
    description: "Redis connection string"
    environments: ["staging", "prod"]
    consumers: ["dev", "gha", "eks"]

  - name: "openai-api-key"
    description: "OpenAI API key for AI features"
    environments: ["staging", "prod"]
    consumers: ["dev", "eks"]             # Not needed in CI

  - name: "stripe-key"
    description: "Stripe API key"
    environments: ["staging", "prod"]
    consumers: ["eks"]                    # Only the running app needs this

aws_dynamic_credentials:
  - role_suffix: "deploy"                 # Creates roles: clientA-staging-deploy, clientA-prod-deploy
    description: "Scoped AWS creds for infrastructure deployment"
    environments: ["staging", "prod"]
    consumers: ["dev", "gha"]
    staging_ttl: "1h"
    prod_ttl: "30m"

shared_secrets:                           # Which shared secrets this project uses
  - path: "shared/github-token"
    consumers: ["dev"]
  - path: "shared/dockerhub-creds"
    consumers: ["gha", "eks"]

consumers:
  dev:                                    # Local dev / Claude Code
    auth_method: "approle"
    token_ttl: "2h"
    
  gha:                                    # GitHub Actions
    auth_method: "approle"
    token_ttl: "30m"
    
  eks:                                    # EKS pods
    auth_method: "kubernetes"
    auth_path: "kubernetes-eks"
    service_account: "clientA-app"
    namespace_template: "clientA-{environment}"  # clientA-staging, clientA-prod
    
  ecs:                                    # ECS tasks (if applicable)
    auth_method: "aws-iam"
    iam_role_template: "arn:aws:iam::<account-id>:role/clientA-{environment}-task-role"
```

The manifest is declarative — it says what, not how. The `onboard-project.sh` script reads it and creates all the OpenBao resources. The session launcher reads it and configures the agent's access scope. The validate script checks that OpenBao's actual state matches.

### 4.8 Project Onboarding

The `onboard-project.sh` script reads a `.vault-manifest.yaml` and creates all required OpenBao resources: policies, AppRoles, K8s auth roles, AWS auth roles.

**What it does:**

```
onboard-project.sh <path-to-manifest>
    │
    ├─ 1. Parse manifest: project name, environments, secrets, consumers
    │
    ├─ 2. Validate: check KV paths exist (warn if secrets not yet stored)
    │
    ├─ 3. Generate policies:
    │     For each (environment × consumer) combination:
    │       - Render policy from template
    │       - Write: bao policy write <project>-<env>-<consumer> <policy.hcl>
    │
    ├─ 4. Create auth roles:
    │     For each consumer:
    │       AppRole consumers → bao write auth/approle/role/<project>-<env>-<consumer>
    │       K8s consumers     → bao write auth/kubernetes-<path>/role/<project>-<env>
    │       AWS IAM consumers → bao write auth/aws/role/<project>-<env>-<consumer>
    │
    ├─ 5. Create AWS dynamic credential roles (if defined):
    │     bao write aws/roles/<project>-<env>-<role_suffix>
    │
    ├─ 6. Output:
    │     - Summary of created resources
    │     - role_id values for AppRole consumers (store in GitHub Actions secrets)
    │     - K8s ServiceAccount requirements for EKS consumers
    │     - IAM role ARN requirements for ECS consumers
    │
    └─ 7. Write generated policies to policies/generated/ for git tracking
```

**Usage:**

```bash
# Onboard a new project
./onboarding/onboard-project.sh /path/to/clientA-platform/.vault-manifest.yaml

# Output:
# ✓ Policy clientA-platform-staging-dev created
# ✓ Policy clientA-platform-staging-gha created
# ✓ Policy clientA-platform-staging-eks created
# ✓ Policy clientA-platform-prod-gha created
# ✓ Policy clientA-platform-prod-eks created
# ✓ AppRole dev-clientA-platform-staging created (role_id: abc-123)
# ✓ AppRole gha-clientA-platform-staging created (role_id: def-456)
# ✓ AppRole gha-clientA-platform-prod created (role_id: ghi-789)
# ✓ K8s role clientA-platform-staging created (SA: clientA-app, NS: clientA-staging)
# ✓ K8s role clientA-platform-prod created (SA: clientA-app, NS: clientA-prod)
# ✓ AWS dynamic role clientA-staging-deploy created
# ✓ AWS dynamic role clientA-prod-deploy created
#
# ⚠ Secret not yet stored: secret/projects/clientA-platform/staging/database-url
# ⚠ Secret not yet stored: secret/projects/clientA-platform/staging/redis-url
#   Store them with: bao kv put secret/projects/clientA-platform/staging/<name> value="..."
#
# GitHub Actions setup:
#   Store BAO_ROLE_ID_STAGING=def-456 in repo settings
#   Store BAO_ROLE_ID_PROD=ghi-789 in repo settings
#   Generate secret_ids: bao write -f auth/approle/role/gha-clientA-platform-staging/secret-id
```

**Manifest validation (run before onboarding):**

```bash
# validate-manifest.sh — catches privilege creep before policy creation
set -euo pipefail
MANIFEST="$1"

# No prod paths in staging consumers
if yq '.secrets[] | select(.environments[] == "staging") | select(.consumers[] | test("prod"))' "$MANIFEST" | grep -q .; then
  echo "ERROR: Staging secrets cannot have prod consumers" >&2; exit 1
fi

# No wildcards in secret names
if yq '.secrets[].name' "$MANIFEST" | grep -q '\*'; then
  echo "ERROR: Wildcard secret names are not allowed" >&2; exit 1
fi

# Valid consumer types only
VALID_CONSUMERS="dev gha-deploy eks-app ecs-task"
for consumer in $(yq '.secrets[].consumers[]' "$MANIFEST"); do
  if ! echo "$VALID_CONSUMERS" | grep -qw "$consumer"; then
    echo "ERROR: Unknown consumer type: $consumer" >&2; exit 1
  fi
done

echo "Manifest validation passed"
```

Add `--dry-run` flag to `onboard-project.sh` that shows what policies and AppRoles will be created without committing them to OpenBao.

**Validation (drift detection):**

```bash
# Check if OpenBao state matches the manifest
./onboarding/validate-project.sh /path/to/clientA-platform/.vault-manifest.yaml

# Output:
# ✓ Policy clientA-platform-staging-dev matches manifest
# ✗ DRIFT: Policy clientA-platform-staging-gha allows secret/data/shared/npm-token
#          but manifest does not declare shared/npm-token for gha consumer
# ✗ MISSING: Secret secret/projects/clientA-platform/prod/stripe-key not stored in OpenBao
```

### 4.9 DX Summary — From New Project to Secrets Flowing

The complete developer experience for onboarding a new project:

```
Day 0: New project starts
  │
  ├─ 1. Create .vault-manifest.yaml in the repo
  │     (declare secrets, environments, consumers)
  │
  ├─ 2. Run onboard-project.sh
  │     (creates policies, AppRoles, auth roles automatically)
  │
  ├─ 3. Store the actual secret values in OpenBao
  │     bao kv put secret/projects/<project>/staging/<name> value="..."
  │     bao kv put secret/projects/<project>/prod/<name> value="..."
  │
  ├─ 4. Store BAO_ROLE_ID + BAO_SECRET_ID in GitHub repo settings
  │     (2 secrets per environment in GitHub — everything else is in OpenBao)
  │
  ├─ 5. For EKS: create ServiceAccount in the target namespace
  │     For ECS: ensure task role ARN matches what's in the manifest
  │
  └─ 6. Done. All consumers can fetch secrets.

Day N: Rotate a secret
  │
  └─ bao kv put secret/projects/<project>/staging/database-url value="new-value"
     │
     └─ Next time any consumer fetches, they get the new value.
        No GitHub Settings update. No K8s Secret update. No ECS redeploy.
        One command.

Day N: Add a new secret to an existing project
  │
  ├─ 1. Add the secret to .vault-manifest.yaml
  ├─ 2. Run onboard-project.sh again (idempotent — updates policies, skips existing)
  ├─ 3. Store the value: bao kv put ...
  └─ 4. Consumers pick it up on next fetch.

Day N: Offboard a project
  │
  └─ Run offboard-project.sh
     (revokes AppRoles, deletes policies, optionally deletes KV paths)
```

---

## Phase 5: Backup and Disaster Recovery

> **Alternative:** OpenBao's built-in snapshot agent can automate Raft snapshots without cron + bash. Configure via `bao operator raft snapshot-agent` for more reliable, integrated backups with built-in retry and monitoring.

### 5.1 backup.sh

```bash
#!/bin/bash
set -euo pipefail

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
SNAPSHOT_FILE="/tmp/openbao-raft-${TIMESTAMP}.snap"
BUCKET="openbao-raft-backups-<account-id>"

export BAO_ADDR="http://<tailscale-ip>:8200"

bao operator raft snapshot save "$SNAPSHOT_FILE"
aws s3 cp "$SNAPSHOT_FILE" "s3://${BUCKET}/snapshots/${TIMESTAMP}.snap" \
  --sse aws:kms \
  --sse-kms-key-id "<backup-kms-key-id>"
rm -f "$SNAPSHOT_FILE"

echo "[$(date)] Backup completed: ${TIMESTAMP}.snap"
```

Runs every 6 hours via cron. OpenBao token for snapshot operations stored in a file readable only by root, with a long TTL policy that only allows `sys/storage/raft/snapshot`.

**Production backup.sh with retry and verification:**

```bash
#!/bin/bash
# backup.sh — production version with retry, verification, and CloudWatch metric
set -euo pipefail

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
SNAPSHOT_FILE="/tmp/openbao-raft-${TIMESTAMP}.snap"
BUCKET="openbao-raft-backups-<account-id>"
BACKUP_KMS_KEY="<backup-kms-key-id>"
MAX_RETRIES=3
RETRY_DELAY=30

export BAO_ADDR="http://<tailscale-ip>:8200"
export BAO_TOKEN=$(cat /etc/openbao/backup-token)

# Health check — abort if OpenBao is sealed or unreachable
if ! bao status -format=json 2>/dev/null | jq -e '.sealed == false' > /dev/null; then
  echo "[$(date)] ERROR: OpenBao is sealed or unreachable. Skipping backup."
  aws cloudwatch put-metric-data \
    --namespace "OpenBao" \
    --metric-name "BackupResult" \
    --value 0 \
    --unit "Count" \
    --dimensions Name=InstanceId,Value=$(ec2-metadata -i | cut -d' ' -f2) \
    2>/dev/null || true
  exit 1
fi

# Take snapshot with retry
for attempt in $(seq 1 $MAX_RETRIES); do
  if bao operator raft snapshot save "$SNAPSHOT_FILE" 2>/dev/null; then
    break
  fi
  if [ "$attempt" -eq "$MAX_RETRIES" ]; then
    echo "[$(date)] ERROR: Snapshot failed after $MAX_RETRIES attempts."
    aws cloudwatch put-metric-data \
      --namespace "OpenBao" \
      --metric-name "BackupResult" \
      --value 0 \
      --unit "Count" \
      --dimensions Name=InstanceId,Value=$(ec2-metadata -i | cut -d' ' -f2) \
      2>/dev/null || true
    exit 1
  fi
  echo "[$(date)] WARN: Snapshot attempt $attempt failed. Retrying in ${RETRY_DELAY}s..."
  sleep "$RETRY_DELAY"
done

# Verify snapshot is non-empty
SNAP_SIZE=$(stat -c%s "$SNAPSHOT_FILE" 2>/dev/null || stat -f%z "$SNAPSHOT_FILE" 2>/dev/null)
if [ "$SNAP_SIZE" -lt 1024 ]; then
  echo "[$(date)] ERROR: Snapshot file suspiciously small (${SNAP_SIZE} bytes). Aborting upload."
  rm -f "$SNAPSHOT_FILE"
  exit 1
fi

# Upload to S3 with retry
for attempt in $(seq 1 $MAX_RETRIES); do
  if aws s3 cp "$SNAPSHOT_FILE" "s3://${BUCKET}/snapshots/${TIMESTAMP}.snap" \
    --sse aws:kms \
    --sse-kms-key-id "$BACKUP_KMS_KEY" 2>/dev/null; then
    break
  fi
  if [ "$attempt" -eq "$MAX_RETRIES" ]; then
    echo "[$(date)] ERROR: S3 upload failed after $MAX_RETRIES attempts."
    rm -f "$SNAPSHOT_FILE"
    exit 1
  fi
  echo "[$(date)] WARN: Upload attempt $attempt failed. Retrying in ${RETRY_DELAY}s..."
  sleep "$RETRY_DELAY"
done

# Verify upload exists in S3
if ! aws s3 ls "s3://${BUCKET}/snapshots/${TIMESTAMP}.snap" > /dev/null 2>&1; then
  echo "[$(date)] ERROR: Upload verification failed — object not found in S3."
  rm -f "$SNAPSHOT_FILE"
  exit 1
fi

rm -f "$SNAPSHOT_FILE"

# Report success metric to CloudWatch
aws cloudwatch put-metric-data \
  --namespace "OpenBao" \
  --metric-name "BackupResult" \
  --value 1 \
  --unit "Count" \
  --dimensions Name=InstanceId,Value=$(ec2-metadata -i | cut -d' ' -f2) \
  2>/dev/null || true

echo "[$(date)] Backup completed: ${TIMESTAMP}.snap (${SNAP_SIZE} bytes)"
```

> **CloudWatch integration:** The `BackupResult` metric (1=success, 0=failure) allows you to create a CloudWatch alarm that fires if no successful backup occurs within 24 hours. This catches silent backup failures that cron alone cannot detect.

### 5.2 restore.sh (disaster recovery runbook)

1. `terraform apply` — spins up a fresh EC2 instance (all infra recreated)
2. SSM in, verify OpenBao is running but uninitialized
3. Download latest snapshot: `aws s3 cp s3://<bucket>/snapshots/<latest>.snap /tmp/restore.snap`
4. `bao operator raft snapshot restore -force /tmp/restore.snap`
5. OpenBao auto-unseals via KMS, comes up with all previous state
6. Verify: `bao status`, `bao secrets list`, spot-check a secret read
7. Update Tailscale if the new instance has a different Tailscale IP (unlikely if you set a stable hostname)

**Target recovery time: 15-20 minutes** if the script is tested and the operator has done it before.

### 5.3 Test the Restore Path

Schedule a quarterly restore drill:
1. Spin up a temporary EC2 instance
2. Restore the latest snapshot
3. Verify data integrity
4. Tear down the test instance

If you haven't tested your restore, you don't have backups.

---

## Phase 6: Ongoing Operations

### 6.1 Patching

- OS: `unattended-upgrades` handles security patches automatically
- OpenBao: subscribe to OpenBao security advisories. Upgrade by downloading the new binary, replacing it, and restarting the systemd service. OpenBao handles unseal automatically on restart via KMS. Test upgrades on a temporary instance first if it's a major version bump.

### 6.2 Secret Rotation

- Static KV secrets: establish a rotation schedule (90 days for API keys, 30 days for high-value credentials)
- AWS dynamic secrets: no rotation needed — they're ephemeral by design
- OpenBao's own credentials (the IAM user for the AWS secrets engine): rotate every 90 days

### Automated Secret-ID Rotation

**systemd timer for daily rotation (on dev machine or CI host):**

```ini
# /etc/systemd/system/openbao-secret-id-rotate.timer
[Unit]
Description=Rotate OpenBao AppRole secret_id daily

[Timer]
OnCalendar=*-*-* 04:00:00
Persistent=true

[Install]
WantedBy=timers.target
```

```ini
# /etc/systemd/system/openbao-secret-id-rotate.service
[Unit]
Description=Rotate OpenBao AppRole secret_id

[Service]
Type=oneshot
ExecStart=/usr/local/bin/rotate-secret-id.sh
```

```bash
#!/bin/bash
# rotate-secret-id.sh
set -euo pipefail
NEW_SECRET_ID=$(bao write -f -field=secret_id auth/approle/role/claude-code-agent/secret-id)
echo "$NEW_SECRET_ID" > /etc/openbao/secret-id
chmod 0600 /etc/openbao/secret-id
```

**GitHub Actions constraint:** GHA secrets are static — you cannot automate secret_id rotation for GHA-stored credentials. Mitigate by using very short token TTLs (15-30 min) for CI AppRoles, or move to self-hosted runners with Kubernetes auth (which avoids secret_id entirely).

### 6.3 Monitoring Checklist

- CloudWatch: instance health, CPU, disk (set alarm at 80% EBS usage)
- OpenBao audit logs: watch for failed authentication attempts, unexpected policy denials
- KMS CloudTrail: alert on unseal operations outside normal restart patterns
- Tailscale admin: review connected devices monthly, remove stale nodes

### 6.4 Cost Breakdown (monthly)

| Resource | Estimated Cost |
|---|---|
| EC2 t4g.micro (on-demand) | ~$6.10 |
| EBS 30GB gp3 | ~$2.40 |
| KMS (2 keys, minimal usage) | ~$2.00 |
| S3 (< 1GB backups) | ~$0.02 |
| Data transfer (Tailscale) | ~$0.00 |
| CloudWatch (basic) | ~$0.00 |
| **Total** | **~$10.50/month** |

After free tier expires. During free tier: ~$2-3/month (KMS + minor S3).

**Revised estimate (realistic):**

| Component | Monthly Cost |
|---|---|
| EC2 t4g.micro (or t4g.small) | $6-13 |
| EBS 30GB gp3 | $2.40 |
| KMS (2 keys + request charges) | $2.50-3.00 |
| S3 (backups, <1GB) | $0.05 |
| CloudWatch (audit log shipping) | $0.50-2.00 |
| Data transfer (Tailscale) | $0.50-1.00 |
| **Total** | **$12-22/mo** |

The original ~$7/mo estimate omits KMS request charges, CloudWatch log ingestion, and data transfer costs. Budget $15/mo for t4g.micro, $22/mo for t4g.small.

**Two-tier cost model:**

| Component | Minimal (t4g.micro, no VPC endpoints) | Full (t4g.small, VPC endpoints, CW agent) |
|---|---|---|
| EC2 instance | $6.10 | $12.70 |
| EBS 30GB gp3 | $2.40 | $2.40 |
| KMS (2 keys + requests) | $2.50 | $3.00 |
| S3 (backups, <1GB) | $0.05 | $0.05 |
| CloudWatch (basic alarms) | $0.00 | $0.00 |
| CloudWatch (log ingestion + metrics) | $0.00 | $1.50 |
| Data transfer (Tailscale) | $0.50 | $1.00 |
| SNS (alarm notifications) | $0.00 | $0.00 |
| VPC Interface Endpoints (KMS, SSM) | $0.00 | $14.40 |
| S3 Gateway Endpoint | $0.00 | $0.00 |
| SSM Session Manager | $0.00 | $0.00 |
| **Total** | **~$12/mo** | **~$35/mo** |

> **VPC endpoints are optional.** Without them, AWS API calls route through the internet gateway (or NAT). This is fine for a Tailscale-only instance with no inbound rules. Add VPC endpoints only if you move to a private subnet with no internet access, or if compliance requires traffic to stay within the AWS network. The S3 Gateway endpoint is free and worth adding regardless.
>
> **Realistic budget:** $20/mo covers the minimal tier comfortably. $41/mo covers the full tier with headroom for KMS request spikes and unexpected data transfer.

---

## Phase 7: Harness Engineering Layer

Phases 1-6 give you a working OpenBao that agents can authenticate against. This phase upgrades the integration model from "wrapper script injects env vars" to "harness mediates all secret access." This is the difference between a password manager and a secrets platform.

### 7.1 Why the Wrapper Model Breaks Down

The Phase 4/5 wrapper script (`claude-code-vault.sh` from agents.md) pre-fetches all secrets at session start and dumps them into environment variables. This works for solo local dev. It fails in these real scenarios:

- **Blast radius:** Agent working on frontend has AWS deploy creds in its environment. Every subprocess inherits every credential.
- **Token expiry mid-task:** 1h TTL runs out during a long Terraform apply. Agent is mid-mutation with no way to re-authenticate.
- **Context switching:** Moving from client-A to client-B requires killing the session and restarting with different creds. No hot-switch.
- **Sub-agent inheritance:** Claude Code shells out to `terraform`, `aws cli`, `curl` — all inherit the full credential set. A rogue `curl` exfiltrates everything.
- **No audit correlation:** OpenBao logs show "claude-code-agent read secret X." Not "claude-code-agent read secret X during task 'deploy landing page for client-A' in session abc123."

The wrapper model is retained as "Simple Mode" for quick local dev. Everything below is "Harness Mode" — the primary production model.

### 7.2 bao agent as the Credential Sidecar

Instead of custom bash wrappers managing token lifecycle, deploy `bao agent` (OpenBao's agent mode) as a persistent background process on any machine running agents.

**What bao agent handles:**

- Auto-auth via AppRole (or Kubernetes SA, or any auth method)
- Token renewal — bao agent renews the token before TTL expiry, handles re-auth on failure, manages grace periods
- Secret caching — reduces OpenBao API calls, serves from local cache with TTL awareness
- Template rendering — can write secrets to templated files (`.env` templates, config files) that agents read
- API proxy — runs a local listener (e.g., `localhost:8100`) that agents can hit as an OpenBao proxy without needing a token themselves

**Installation on agent hosts:**

bao agent runs as a systemd service on your dev machine, as a sidecar container in K8s pods (via OpenBao Agent Injector), or baked into the EC2 user-data for cloud-based agent runners.

**bao agent config for local dev machine:**

```hcl
# openbao-agent.hcl

vault {  # OpenBao uses the same HCL stanza name
  address = "http://openbao:8200"  # MagicDNS via Tailscale
}

auto_auth {
  method "approle" {
    config = {
      role_id_file_path   = "/home/<user>/.openbao/role-id"
      secret_id_file_path = "/home/<user>/.openbao/secret-id"
      remove_secret_id_file_after_reading = false
    }
  }

  sink "file" {
    config = {
      path = "/home/<user>/.openbao/agent-token"
      mode = 0600
    }
  }
}

cache {
  use_auto_auth_token = true
}

listener "tcp" {
  address     = "127.0.0.1:8100"
  tls_disable = true
}

template {
  source      = "/home/<user>/.openbao/templates/agent-env.tpl"
  destination = "/home/<user>/.openbao/rendered/agent.env"
  perms       = 0600
}
```

**Template file (`agent-env.tpl`):**

```
{{ with secret "aws/creds/agent-deploy" }}
AWS_ACCESS_KEY_ID={{ .Data.access_key }}
AWS_SECRET_ACCESS_KEY={{ .Data.secret_key }}
AWS_SESSION_TOKEN={{ .Data.security_token }}
{{ end }}
{{ with secret "secret/data/agents/claude-code/github-token" }}
GITHUB_TOKEN={{ .Data.data.value }}
{{ end }}
```

bao agent re-renders the template when secrets change or leases expire. Agents source the rendered file or hit the local proxy. Token lifecycle is fully managed — no bash cron, no background subshells, no race conditions.

**Updated repo structure additions:**

```
vault-infra/
├── ...existing structure...
├── openbao-agent/
│   ├── openbao-agent.hcl            # Agent config for local dev machines
│   ├── openbao-agent-k8s.hcl        # Agent config for K8s sidecar
│   ├── openbao-agent.service         # systemd unit file
│   ├── templates/
│   │   ├── agent-env.tpl            # Generic agent env template
│   │   ├── claude-code-env.tpl      # Claude Code specific
│   │   ├── n8n-env.tpl             # n8n specific
│   │   └── ci-env.tpl              # CI/CD specific
│   └── install-openbao-agent.sh     # Setup script for dev machines
```

### 7.3 Session-Scoped Identity and Metadata

When the harness (your tmux session launcher, a CI pipeline, an orchestration script) starts an agent session, it should create an OpenBao token with metadata that ties every audit log entry back to the specific task.

**Token creation with session metadata:**

```bash
# The harness creates a session-scoped token
SESSION_ID=$(uuidgen)
CLIENT="client-a"
TASK="deploy-landing-page"
REPO="works-on-my-cloud/client-a-infra"

AGENT_TOKEN=$(bao token create \
  -policy=agent-aws-${CLIENT} \
  -ttl=4h \
  -display-name="claude-code/${CLIENT}/${TASK}" \
  -metadata="session_id=${SESSION_ID}" \
  -metadata="client=${CLIENT}" \
  -metadata="task=${TASK}" \
  -metadata="repo=${REPO}" \
  -metadata="started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  -field=token)
```

Every OpenBao audit log entry for this token now includes the session_id, client, task, and repo. When you're debugging "who accessed the production database password at 3am," you can trace it to the exact agent session and task.

**OpenBao entity aliases for persistent agent identity:**

For agents that authenticate repeatedly (e.g., Claude Code across multiple sessions), create an OpenBao entity that aggregates all their tokens:

```bash
# Create entity for Claude Code agent
bao write identity/entity \
  name="claude-code-agent" \
  metadata=agent_type="claude-code" \
  metadata=owner="chinmay"

# Alias the AppRole auth to this entity
bao write identity/entity-alias \
  name=<role_id> \
  canonical_id=<entity_id> \
  mount_accessor=<approle_mount_accessor>
```

Now OpenBao tracks all activity from this agent across sessions under a single identity, even as tokens rotate.

### 7.4 Multi-Client Isolation

For the agency use case — working on client-A's infra, then switching to client-B — the harness must enforce credential isolation per client-environment pair.

**AppRole-per-client model:**

```bash
# Client A — staging
bao write auth/approle/role/agent-clientA-staging \
  token_ttl=2h \
  token_policies="clientA-staging-aws,clientA-staging-kv"

# Client A — production
bao write auth/approle/role/agent-clientA-prod \
  token_ttl=1h \
  token_policies="clientA-prod-aws,clientA-prod-kv"

# Client B — staging
bao write auth/approle/role/agent-clientB-staging \
  token_ttl=2h \
  token_policies="clientB-staging-aws,clientB-staging-kv"
```

**Corresponding policies:**

```hcl
# policies/clientA-staging-aws.hcl
path "aws/sts/clientA-staging-deploy" {
  capabilities = ["read"]
}

path "secret/data/clients/clientA/staging/*" {
  capabilities = ["read"]
}

# No access to clientA prod, no access to clientB anything
```

**Harness selects the right role at session launch:**

```bash
# Session launcher reads project context
CLIENT=$(git config --get project.client || echo "personal")
ENV=$(git config --get project.environment || echo "staging")
ROLE="agent-${CLIENT}-${ENV}"

# Authenticate with the context-appropriate AppRole
bao write auth/approle/login \
  role_id=$(bao read -field=role_id auth/approle/role/${ROLE}/role-id) \
  secret_id=$(bao write -f -field=secret_id auth/approle/role/${ROLE}/secret-id)
```

The agent physically cannot access client-B's secrets while working on client-A. Isolation is enforced by OpenBao policy, not by developer discipline.

### 7.5 Lease Tracking and Session Cleanup

The harness must track all OpenBao leases created during a session and revoke them on exit — normal or abnormal.

**Session lifecycle script (`session-lifecycle.sh`):**

```bash
#!/bin/bash
set -euo pipefail

BAO_ADDR="http://openbao:8200"
SESSION_ID=$(uuidgen)
LEASE_FILE="/tmp/openbao-leases-${SESSION_ID}"
touch "$LEASE_FILE"

# Cleanup function — runs on exit, SIGINT, SIGTERM
cleanup() {
  echo "[session] Revoking ${SESSION_ID} leases..."
  while IFS= read -r lease_id; do
    bao lease revoke "$lease_id" 2>/dev/null || true
  done < "$LEASE_FILE"

  if [ -n "${AGENT_TOKEN:-}" ]; then
    BAO_TOKEN="$AGENT_TOKEN" bao token revoke -self 2>/dev/null || true
  fi

  rm -f "$LEASE_FILE"
  echo "[session] Cleanup complete."
}
trap cleanup EXIT INT TERM

# Create session token with metadata
AGENT_TOKEN=$(bao token create \
  -policy=agent-aws \
  -ttl=4h \
  -metadata="session_id=${SESSION_ID}" \
  -field=token)
export BAO_TOKEN="$AGENT_TOKEN"

# Fetch AWS creds and track the lease
AWS_RESPONSE=$(bao read -format=json aws/creds/agent-deploy)
echo "$AWS_RESPONSE" | jq -r '.lease_id' >> "$LEASE_FILE"

export AWS_ACCESS_KEY_ID=$(echo "$AWS_RESPONSE" | jq -r '.data.access_key')
export AWS_SECRET_ACCESS_KEY=$(echo "$AWS_RESPONSE" | jq -r '.data.secret_key')
export AWS_SESSION_TOKEN=$(echo "$AWS_RESPONSE" | jq -r '.data.security_token')

# Launch the agent
claude "$@"

# cleanup runs automatically via trap
```

When you `ctrl-c` a runaway agent, the trap fires, all AWS STS creds are revoked immediately (not waiting for TTL), and the OpenBao token is destroyed. No lingering credentials.

**For the tmux session launcher:** The teardown function in your tmux session script should call this cleanup before killing the pane. This integrates directly with the tmux + git worktrees launcher you've been building.

### 7.6 Credential Request Gating (High-Risk Approval)

Some secret accesses should pause for human approval. Control Groups are enterprise-only in HashiCorp Vault, but the harness can implement this at the wrapper level.

**Risk classification in the harness:**

```bash
# risk-gate.sh — called before any secret fetch

classify_risk() {
  local secret_path="$1"
  case "$secret_path" in
    */prod/*)           echo "high" ;;
    aws/creds/*-prod*)  echo "high" ;;
    secret/data/clients/*/prod/*) echo "high" ;;
    *)                  echo "low" ;;
  esac
}

gate_request() {
  local path="$1"
  local risk=$(classify_risk "$path")

  if [ "$risk" = "high" ]; then
    echo "[GATE] High-risk secret request: $path"
    echo "[GATE] Sending approval request..."

    # Send notification (Slack webhook, Telegram bot, push notification)
    curl -s -X POST "$SLACK_WEBHOOK_URL" \
      -d "{\"text\":\"Agent requesting prod credentials: ${path}. Approve? Reply 'yes ${SESSION_ID}'\"}"

    # Block until approval (poll a shared state, or wait for file)
    echo "[GATE] Waiting for approval..."
    # Implementation: poll an S3 object, a Redis key, or a simple HTTP endpoint
    # that your phone/Slack bot writes to when you approve
    wait_for_approval "$SESSION_ID" || {
      echo "[GATE] Request denied or timed out."
      exit 1
    }
  fi
}
```

**Approval backend (simplest: S3 polling):**

```bash
wait_for_approval() {
  local session_id="$1"
  local timeout=300  # 5 minutes
  local interval=5
  local elapsed=0

  # Create approval request
  echo '{"status":"pending","session":"'$session_id'","requested_at":"'$(date -u +%FT%TZ)'"}' \
    | aws s3 cp - "s3://vault-approvals/${session_id}.json"

  echo "Approval required. Waiting up to ${timeout}s..." >&2

  while [ $elapsed -lt $timeout ]; do
    status=$(aws s3 cp "s3://vault-approvals/${session_id}.json" - 2>/dev/null | jq -r '.status')
    case "$status" in
      approved) return 0 ;;
      denied)   echo "Request denied" >&2; return 1 ;;
      *)        sleep $interval; elapsed=$((elapsed + interval)) ;;
    esac
  done

  echo "Approval timed out after ${timeout}s" >&2
  return 1
}
```

To approve: `echo '{"status":"approved"}' | aws s3 cp - "s3://vault-approvals/${SESSION_ID}.json"`

This ties into your React Native remote control for long-running agents — the agent requests prod creds, your phone buzzes, you approve or deny. Low-risk requests (staging KV reads) flow through instantly.

### 7.7 Sub-Agent Credential Isolation

When Claude Code runs `terraform apply` or `aws s3 cp`, those subprocesses inherit the full environment. To limit this, the harness can use a local credential proxy pattern.

**Option A: bao agent API proxy (recommended)**

bao agent's cache listener on `localhost:8100` acts as a credential proxy. Instead of injecting `AWS_ACCESS_KEY_ID` into the environment, configure the AWS SDK to fetch credentials from a local endpoint:

```bash
# Instead of env vars, use AWS credential_process
# ~/.aws/config
[profile agent]
credential_process = /usr/local/bin/openbao-credential-helper.sh
```

```bash
# openbao-credential-helper.sh
#!/bin/bash
CREDS=$(curl -s http://localhost:8100/v1/aws/creds/agent-deploy \
  -H "X-Vault-Token: $(cat ~/.openbao/agent-token)")  # Header name unchanged for API compat

echo "{
  \"Version\": 1,
  \"AccessKeyId\": \"$(echo $CREDS | jq -r '.data.access_key')\",
  \"SecretAccessKey\": \"$(echo $CREDS | jq -r '.data.secret_key')\",
  \"SessionToken\": \"$(echo $CREDS | jq -r '.data.security_token')\"
}"
```

Now the AWS credentials are never in the environment. Each subprocess that needs AWS access calls the credential_process, which goes through bao agent's proxy. The proxy handles caching and lease management. A rogue `curl` to an external endpoint doesn't carry AWS creds in the environment.

**Option B: Process-specific env injection**

For non-AWS tools that can't use credential_process, use `env -i` to launch subprocesses with a minimal environment:

```bash
# Only pass the specific creds this subprocess needs
env -i PATH="$PATH" HOME="$HOME" \
  GITHUB_TOKEN="$(bao kv get -field=value secret/agents/ci/github-token)" \
  terraform apply
```

This prevents credential leakage across subprocesses at the cost of more verbose invocations.

---

## Phase 8: OpenBao MCP Server

> **Note:** The MCP specification has evolved significantly since this document was written. Verify tool definitions and session config format against https://modelcontextprotocol.io/specification before implementation.

The highest-leverage integration for agentic coding. Instead of wrapper scripts and env vars, expose OpenBao as a set of tools that any MCP-compatible agent can call natively.

### 8.1 Architecture

```
┌──────────────────────────────────────────────┐
│          Agent (Claude Code, etc.)            │
│                                              │
│  "I need AWS credentials to deploy this"     │
│       │                                      │
│       ▼                                      │
│  Tool call: get_aws_credentials              │
│    params: { role: "agent-deploy" }          │
└──────┬───────────────────────────────────────┘
       │ (MCP protocol)
       ▼
┌──────────────────────────────────────────────┐
│          OpenBao MCP Server                  │
│                                              │
│  1. Validates request against session policy │
│  2. Checks risk classification              │
│  3. Authenticates to OpenBao (or reuses token)│
│  4. Fetches secret                          │
│  5. Tracks lease for cleanup                │
│  6. Injects session metadata into audit     │
│  7. Returns credential to agent             │
└──────┬───────────────────────────────────────┘
       │ (OpenBao API over Tailscale)
       ▼
┌──────────────────────────────────────────────┐
│          OpenBao Server (EC2)                │
└──────────────────────────────────────────────┘
```

### 8.2 MCP Tool Definitions

The OpenBao MCP server exposes these tools:

**`read_secret`** — Read a static secret from KV v2

```json
{
  "name": "read_secret",
  "description": "Read a secret from OpenBao KV store. Returns the secret value for the given path. Only paths allowed by your current session policy are accessible.",
  "parameters": {
    "path": {
      "type": "string",
      "description": "KV secret path, e.g. 'agents/claude-code/github-token'"
    }
  }
}
```

**`get_aws_credentials`** — Generate ephemeral AWS STS credentials

```json
{
  "name": "get_aws_credentials",
  "description": "Generate short-lived AWS credentials for infrastructure operations. Credentials auto-expire. Only roles allowed by your session policy are accessible.",
  "parameters": {
    "role": {
      "type": "string",
      "description": "AWS secrets engine role name, e.g. 'agent-deploy'"
    },
    "ttl": {
      "type": "string",
      "description": "Optional TTL override, e.g. '30m', '1h'. Max 4h.",
      "default": "1h"
    }
  }
}
```

**`list_available_secrets`** — Show what the agent can access

```json
{
  "name": "list_available_secrets",
  "description": "List secret paths and AWS roles available to the current session. Use this to discover what credentials are available before requesting them.",
  "parameters": {}
}
```

**`encrypt_data`** — Transit encryption-as-a-service

```json
{
  "name": "encrypt_data",
  "description": "Encrypt sensitive data using OpenBao Transit engine. Returns ciphertext. Use when you need to store sensitive data in non-secure locations.",
  "parameters": {
    "plaintext": {
      "type": "string",
      "description": "Data to encrypt (will be base64-encoded internally)"
    },
    "key_name": {
      "type": "string",
      "description": "Transit encryption key to use",
      "default": "agent-data"
    }
  }
}
```

### 8.3 MCP Server Implementation Approach

The MCP server is a lightweight process (TypeScript/Node or Python) that:

- Runs locally on the agent host alongside bao agent
- Implements the MCP protocol (stdio transport for Claude Code, SSE for remote)
- Maintains a session context: client, environment, task, allowed paths
- Delegates all OpenBao API calls through the local bao agent proxy
- Tracks leases in memory for session cleanup (see Lease Lifecycle below)
- Enforces the risk-gating logic from 7.6 before returning high-risk credentials

**Session initialization:**

When Claude Code or another MCP client connects, the server reads session context from environment variables or a config file set by the harness:

```json
{
  "session_id": "abc-123",
  "client": "client-a",
  "environment": "staging",
  "allowed_kv_paths": ["agents/claude-code/*", "clients/client-a/staging/*"],
  "allowed_aws_roles": ["clientA-staging-deploy"],
  "risk_gate_webhook": "https://hooks.slack.com/..."
}
```

The MCP server uses this to filter and validate every tool call before it reaches OpenBao. The agent can call `list_available_secrets` to discover what's accessible and `get_aws_credentials` to get scoped creds — but only within the boundaries the harness defined for this session.

### Lease Lifecycle in MCP Server

**Data structure:**

```typescript
interface TrackedLease {
  leaseId: string;
  path: string;        // e.g., "aws/creds/agent-deploy"
  ttlSeconds: number;
  createdAt: Date;
}

// In-memory lease tracker
const activeLeases = new Map<string, TrackedLease>();
const MAX_LEASES_PER_SESSION = 50;  // Circuit breaker
```

**Cleanup signal:** The MCP server registers a SIGTERM handler. When Claude Code exits (normally or via ctrl-c), the parent process sends SIGTERM, triggering lease revocation:

```typescript
process.on('SIGTERM', async () => {
  for (const [id, lease] of activeLeases) {
    try {
      await openbaoClient.revokeLease(lease.leaseId);
    } catch (e) {
      // Log failed revocations for manual cleanup
      console.error(`Failed to revoke lease ${lease.leaseId}: ${e.message}`);
      fs.appendFileSync('/tmp/openbao-orphaned-leases.log', `${lease.leaseId}\n`);
    }
  }
  process.exit(0);
});
```

**Circuit breaker:** If `activeLeases.size >= MAX_LEASES_PER_SESSION`, refuse new credential requests. This prevents memory leaks from runaway agents.

**Crash recovery:** On startup, the MCP server checks `/tmp/openbao-orphaned-leases.log` and attempts to revoke any orphaned leases from previous crashed sessions.

### 8.4 Why MCP Over Wrapper Scripts

The fundamental shift: with wrapper scripts, the agent has credentials pushed into its environment. With MCP, the agent pulls credentials when it needs them through a mediated interface.

Benefits:

- **On-demand, not pre-fetched:** Agent only gets credentials it actually requests. Working on frontend code? No AWS creds in memory.
- **Auditable at the tool level:** Every credential request is a discrete tool call with parameters, logged both by MCP and by OpenBao.
- **Gateable:** The MCP server can pause, deny, or modify requests based on risk classification before they reach OpenBao.
- **Agent-native:** The agent understands tools. It can reason about "I need AWS credentials for this task" as a tool call, just like it reasons about reading a file or running a command. No opaque env var magic.
- **Portable:** Any MCP-compatible agent (Claude Code, custom smolagents, future tools) can use the same server without custom wrapper scripts per agent.

### 8.5 Repo Structure Additions

```
vault-infra/
├── ...existing structure...
├── openbao-mcp-server/
│   ├── package.json
│   ├── tsconfig.json
│   ├── src/
│   │   ├── index.ts             # MCP server entrypoint
│   │   ├── tools/
│   │   │   ├── read-secret.ts
│   │   │   ├── get-aws-creds.ts
│   │   │   ├── list-secrets.ts
│   │   │   └── encrypt-data.ts
│   │   ├── openbao-client.ts      # OpenBao API client (via bao agent proxy)
│   │   ├── session.ts           # Session context and policy enforcement
│   │   ├── risk-gate.ts         # Risk classification and approval flow
│   │   └── lease-tracker.ts     # Track and revoke leases on cleanup
│   ├── config/
│   │   └── session-template.json
│   └── README.md
```

### 8.6 Claude Code MCP Configuration

Register the OpenBao MCP server in Claude Code's config:

```json
// ~/.claude/mcp.json
{
  "mcpServers": {
    "openbao": {
      "command": "node",
      "args": ["/path/to/openbao-mcp-server/dist/index.js"],
      "env": {
        "BAO_ADDR": "http://localhost:8100",
        "SESSION_CONFIG": "/home/<user>/.openbao/current-session.json"
      }
    }
  }
}
```

Claude Code now has `read_secret`, `get_aws_credentials`, `list_available_secrets`, and `encrypt_data` as native tools. The agent requests credentials through the tool interface, the MCP server mediates, and OpenBao provides.

### 8.7 Implementation Priority

The OpenBao MCP server is a Phase 8 deliverable — build it after Phases 1-6 are stable and bao agent (Phase 7) is running. The wrapper scripts from agents.md remain the Phase 4 "simple mode" and continue to work. MCP is the upgrade path.

This is also a strong open-source project for the agency — a generic OpenBao MCP server is something the agentic coding community doesn't have yet.

---

## Phase 9: High Availability (Future)

Single-node OpenBao is appropriate for dev/POC but introduces a single point of failure. For agency work with SLA requirements:

**Option A: Multi-node Raft cluster**
- 3 OpenBao nodes in an Auto Scaling Group behind a Network Load Balancer
- Raft consensus handles leader election automatically
- Cost: ~$25-35/mo (3x t4g.micro)

**Option B: Active-standby with cross-region snapshots**
- Primary node in ap-south-1, S3 cross-region replication to a secondary region
- Manual failover: launch new instance from latest snapshot in secondary region
- Cost: ~$15/mo (primary + S3 replication)
- RTO: 10-15 minutes (manual)

**Current constraint:** Phase 1-6 is scoped as dev/POC. The 15-20 minute RTO is acceptable for supervised local development. Upgrade to HA before running unattended multi-client agent workflows with uptime requirements.

---

## Phase 10: Open-Source & Community

This project serves two audiences: the maintainer's own infrastructure needs, and the broader open-source community exploring credential management for agentic workflows. This phase tracks the work to make the project accessible to both.

### 10.1 Documentation Structure

| File | Purpose | Audience |
|------|---------|----------|
| `README.md` | Project overview, quick start, links to detailed docs | Everyone (the front door) |
| `docs/openbao-aws-handbook.md` | Architecture deep dive, security model, operational runbook | Operators deploying their own instance |
| `docs/integration-patterns.md` | Auth patterns, secret access, multi-consumer integration | Developers integrating agents with OpenBao |
| `implementation-plan.md` | Complete build plan with code and operational procedures | Contributors and deployers |
| `CONTRIBUTING.md` | How to contribute, code style, security reporting | Contributors |
| `docs/onecli-integration.md` | Playbook for combining Agentic Vault with OneCLI proxy layer | Operators wanting defense-in-depth |
| `CLAUDE.md` | Project context for Claude Code sessions | Claude Code (internal) |

### 10.2 Examples

- `examples/terraform.tfvars.example` — Copy-and-customize template for deployment variables
- `examples/vault-manifest-simple.yaml` — Minimal single-project manifest for local dev
- `examples/vault-manifest-full.yaml` — Full multi-client, multi-environment manifest with annotations

### 10.3 Community Infrastructure

Current (proportionate to project stage):

- MPL-2.0 license (matches OpenBao)
- CONTRIBUTING.md with development setup, code style, security reporting
- Annotated repo structure showing built vs planned components

Add when needed (after real contributors appear):

- GitHub issue templates and PR templates
- CODE_OF_CONDUCT.md
- CI/CD workflows (terraform fmt check, shellcheck, markdown lint)
- CHANGELOG.md
- GitHub Pages documentation site

### 10.4 Design Principles for Dual-Purpose

- **Terraform stays parameterized.** No hardcoded regions, account IDs, or naming. Everything is configurable via variables with sensible defaults.
- **Documentation is layered.** README routes to the right detailed doc. The implementation plan is the single source of truth for the build sequence. Don't create redundant architecture documents.
- **Examples are copy-and-customize.** Real values with comments, not abstract schemas.
- **Internal context stays separate.** CLAUDE.md is for Claude Code sessions. Humans start with README.md.

---

## References

- OpenBao Documentation: https://openbao.org/docs/
- OpenBao AWS KMS Auto-Unseal: https://openbao.org/docs/configuration/seal/awskms
- OpenBao Integrated Raft Storage: https://openbao.org/docs/configuration/storage/raft
- OpenBao AWS Secrets Engine: https://openbao.org/docs/secrets/aws
- OpenBao KV v2 Secrets Engine: https://openbao.org/docs/secrets/kv/kv-v2
- OpenBao AppRole Auth: https://openbao.org/docs/auth/approle
- OpenBao Kubernetes Auth: https://openbao.org/docs/auth/kubernetes
- OpenBao AWS IAM Auth: https://openbao.org/docs/auth/aws
- OpenBao Policies: https://openbao.org/docs/concepts/policies
- OpenBao Raft Snapshots: https://openbao.org/docs/commands/operator/raft/snapshot
- OpenBao Agent Auto-Auth: https://openbao.org/docs/agent-and-proxy/agent/auto-auth
- OpenBao Agent Caching: https://openbao.org/docs/agent-and-proxy/agent/caching
- OpenBao Agent Templates: https://openbao.org/docs/agent-and-proxy/agent/template
- OpenBao Agent Injector (Kubernetes): https://openbao.org/docs/platform/k8s/injector
- OpenBao CSI Provider: https://openbao.org/docs/platform/k8s/csi
- OpenBao Identity / Entities: https://openbao.org/docs/concepts/identity
- OpenBao Token Metadata: https://openbao.org/docs/concepts/tokens#token-metadata
- External Secrets Operator: https://external-secrets.io/latest/provider/hashicorp-vault/
- GitHub Actions openbao-action: https://github.com/openbao/vault-action
- AWS credential_process: https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sourcing-external.html
- IMDSv2 Enforcement: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html
- KMS Key Policies: https://docs.aws.amazon.com/kms/latest/developerguide/key-policies.html
- Tailscale ACLs: https://tailscale.com/kb/1018/acls
- Tailscale Auth Keys: https://tailscale.com/kb/1085/auth-keys
- MCP Specification: https://modelcontextprotocol.io/specification
- MCP TypeScript SDK: https://github.com/modelcontextprotocol/typescript-sdk
