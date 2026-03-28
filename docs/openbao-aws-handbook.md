# OpenBao on AWS — Architecture & Operations Handbook

## Why OpenBao

- **OpenBao** is a community-maintained fork of HashiCorp Vault, hosted under the Linux Foundation
- HashiCorp Vault moved to the **Business Source License (BSL 1.1)** in August 2023 — it is no longer open-source
- OpenBao is fully open-source (**MPL 2.0**), API-compatible with Vault, and actively developed
- All Vault tooling, SDKs, and integrations work with OpenBao — same API surface, same configuration format
- CLI command: `bao` (drop-in replacement for the `vault` CLI; all subcommands are identical)

---

## Architecture Overview

```
┌──────────────────────────────────────────────────────────────────┐
│                        Tailscale Tailnet                         │
│                                                                  │
│  ┌────────────┐   ┌────────────┐   ┌──────────────────────────┐ │
│  │ Dev Machine│   │ Homelab    │   │ Cloud Agents             │ │
│  │ (Claude    │   │ K8s Nodes  │   │ (CI, Lambda, CrewAI,     │ │
│  │  Code)     │   │ (n8n, Crew)│   │  GitHub Actions)         │ │
│  └─────┬──────┘   └─────┬──────┘   └───────────┬──────────────┘ │
│        │                │                       │                │
│        └────────────────┼───────────────────────┘                │
│                         │                                        │
│                  ┌──────▼───────┐                                │
│                  │   EC2        │                                │
│                  │  OpenBao     │                                │
│                  │  t4g.small   │                                │
│                  │ (Tailscale   │                                │
│                  │  iface only) │                                │
│                  └──────┬───────┘                                │
└─────────────────────────┼────────────────────────────────────────┘
                          │ (internal AWS network)
                 ┌────────┼────────┬──────────┐
                 │        │        │          │
            ┌────▼───┐ ┌──▼──┐ ┌──▼────────┐ ┌▼────┐
            │AWS KMS │ │ S3  │ │CloudWatch │ │ SNS │
            │(unseal)│ │(bkp)│ │(metrics + │ │(alert│
            │        │ │     │ │ logs)     │ │ fan) │
            └────────┘ └─────┘ └───────────┘ └─────┘
```

**Key architectural decisions:**

- **Single-node OpenBao on EC2** with Raft integrated storage — no external database dependency
- **Tailscale WireGuard overlay** for zero-trust network access — no inbound ports, no VPN appliances
- **KMS auto-unseal** eliminates manual intervention on restart or crash recovery
- **S3 for Raft snapshot backups** with lifecycle tiering — 11 nines durability, pennies per month
- **CloudWatch for metrics, alarms, and audit log shipping** — unified operational visibility
- **SNS for alert routing** — fan-out to email, Slack, or PagerDuty

---

## AWS Services Deep Dive

### EC2 (t4g.small)

**What it does for us:** Runs the OpenBao server process and Tailscale daemon.

**Why we chose it:**

- **Graviton ARM (t4g)** = ~20% cheaper than x86 equivalents at the same specs
- **Burst instances** are right-sized for a secrets workload: low sustained CPU with occasional spikes during batch credential generation or policy evaluation
- **2 vCPU, 2 GB RAM** — comfortable headroom for OpenBao + Raft consensus + CloudWatch agent + Tailscale
- Detailed monitoring (1-minute metrics) enabled for responsive alerting

**Security considerations:**

- **IMDSv2 enforced** (`http_tokens = "required"`): prevents SSRF-based credential theft from the instance metadata service. The instance metadata endpoint requires a session token obtained via a PUT request — a GET-only SSRF cannot retrieve credentials
- Instance profile provides temporary credentials — no static AWS keys on the instance

**Cost:** ~$12.41/month on-demand (ap-south-1). Can drop to ~$7.50/month with a 1-year Reserved Instance.

---

### KMS (Auto-Unseal)

**What it does for us:** Encrypts the OpenBao master key. On restart, OpenBao calls KMS `Decrypt` to recover the master key automatically — no human intervention needed.

**Why we chose it:**

- **HSM-backed** (FIPS 140-2 Level 2) — the actual key material never leaves AWS hardware security modules
- **Automatic annual key rotation** (`enable_key_rotation = true`) — AWS manages key versioning transparently
- **Why not Shamir:** Manual unsealing requires 3-of-5 recovery key holders available within minutes of any restart. Unacceptable for a single-operator setup where the server might restart at 3 AM due to a host maintenance event

**Security considerations:**

- Key policy restricts usage to the OpenBao instance role via `kms:ViaService` condition — even if someone obtains the key ARN, they cannot use it outside the EC2 service context
- Separate KMS key for S3 backup encryption — defense in depth (compromising one key does not expose the other)

**Cost:** ~$1/month per key + $0.03 per 10,000 API calls. Two keys (unseal + backup) = ~$2/month.

---

### S3 (Raft Snapshots + Terraform State)

**What it does for us:** Stores Raft snapshot backups and Terraform state files in separate buckets.

**Why we chose it:**

- **11 nines durability** (99.999999999%) — backups survive even if the EC2 instance is destroyed, the AZ goes down, or you accidentally terminate everything
- **Versioning enabled** — recover from accidental overwrites or corrupted uploads
- **S3 native state locking** (Terraform 1.10+, `use_lockfile = true`) — no DynamoDB table needed for Terraform state locking

**Lifecycle tiering for backups:**

| Age | Storage Class | Rationale |
|-----|---------------|-----------|
| 0–30 days | Standard | Recent backups, fast retrieval for DR |
| 30–60 days | Standard-IA | Cheaper, still quick retrieval |
| 60–90 days | Glacier Instant Retrieval | Archival, millisecond retrieval if needed |
| 90+ days | Expire | Older snapshots deleted to control costs |

**Security considerations:**

- **KMS encryption** with a dedicated backup key (separate from the unseal key)
- **Bucket policy: append-only from instance role** — no `s3:DeleteObject` permission, so the instance cannot delete its own backups even if compromised
- **Explicit deny** for any principal not in the allowed list
- **Public access block** at the bucket level — all four S3 public access settings set to `true`

**Cost:** < $1/month for typical snapshot volume (daily snapshots, ~10 MB each, 90-day retention).

---

### CloudWatch (Metrics + Alarms + Logs)

**What it does for us:** Provides operational visibility, alerting, and audit log retention.

**Alarms (6 total):**

| Alarm | Metric | Threshold | Why It Matters |
|-------|--------|-----------|----------------|
| StatusCheck | StatusCheckFailed | >= 1 for 2 min | Instance is unreachable — hardware or network failure |
| CPU High | CPUUtilization | >= 80% for 5 min | Sustained high CPU — possible abuse or runaway process |
| CPU Credits | CPUCreditBalance | <= 20 for 5 min | Burst budget exhausted — instance will throttle to baseline |
| Disk Usage | disk_used_percent | >= 85% for 5 min | Raft WAL or audit logs filling disk |
| Memory Usage | mem_used_percent | >= 85% for 5 min | Memory pressure — OpenBao may OOM |
| KMS Errors | KMS API errors | >= 1 for 1 min | Unseal will fail on next restart if KMS is unreachable |

**Custom metrics** via CloudWatch agent (in the `OpenBao` namespace):
- `disk_used_percent` — not available from EC2 default metrics
- `mem_used_percent` — not available from EC2 default metrics

**Log groups:**

| Log Group | Retention | Contents |
|-----------|-----------|----------|
| `/openbao/audit` | 90 days | Every API call: who accessed what, when, from where |
| `/openbao/system` | 30 days | Server logs: startup, seal/unseal, errors |

**Security considerations:**

- Audit logs can optionally be shipped to S3 with **Object Lock** for immutable retention (compliance use case)
- Log group access controlled via IAM — only admins can read audit logs

**Cost:** ~$3/month basic, $5–15/month with full audit log shipping depending on volume.

---

### SNS (Alert Routing)

**What it does for us:** Fans out CloudWatch alarm notifications to one or more destinations.

**Why we chose it:**

- Single topic (`openbao-alerts`) receives all alarm state changes
- Email subscription for immediate human notification
- Extensible: add Lambda subscriptions for Slack/PagerDuty integration without modifying alarms

**Cost:** Negligible (< $0.01/month). SNS charges per notification, and alarm frequency is low.

---

### SSM Session Manager (Instance Access)

**What it does for us:** Provides shell access to the EC2 instance without SSH keys.

**Why we chose it:**

- **No SSH keys** to manage, rotate, or risk leaking
- **Session recording to S3** — full audit trail of every interactive session
- **MFA enforcement** via IAM policy condition (`aws:MultiFactorAuthPresent`)
- Works through Tailscale — connect via SSM even if you're not on the same network

**Alternative:** Tailscale SSH is simpler for day-to-day access, but SSM adds session recording that Tailscale SSH does not provide.

**Cost:** Free — SSM agent is included with Amazon Linux and the service has no per-session charges.

---

### IAM (Least Privilege)

**What it does for us:** Provides the instance with exactly the permissions it needs — nothing more.

**Design:**

- **Instance profile** with 3 scoped inline policies:
  1. **KMS unseal:** `kms:Decrypt`, `kms:DescribeKey` on the unseal key ARN
  2. **S3 backup:** `s3:PutObject`, `s3:GetObject`, `s3:ListBucket` on the backup bucket (no `s3:DeleteObject`)
  3. **CloudWatch:** `logs:CreateLogStream`, `logs:PutLogEvents`, `cloudwatch:PutMetricData`
- **SSM access** via AWS managed policy attachment (`AmazonSSMManagedInstanceCore`)
- **No static credentials anywhere** — the instance role provides temporary credentials automatically via the metadata service

**KMS policy split:**

- **Key policy** (attached to the KMS key): `kms:ViaService` condition restricting usage to `ec2.ap-south-1.amazonaws.com`
- **IAM policy** (attached to the role): resource ARN scoping to the specific key
- Both must allow for access to succeed — belt and suspenders
- Don't duplicate conditions in both policies; it creates a maintenance burden with no security benefit

---

### VPC + Security Group (Network Isolation)

**What it does for us:** Provides network-level isolation with zero inbound attack surface.

**Security group rules:**

| Direction | Port | Protocol | Destination | Purpose |
|-----------|------|----------|-------------|---------|
| Egress | 443 | TCP | 0.0.0.0/0 | HTTPS (AWS APIs, Tailscale coordination) |
| Egress | 80 | TCP | 0.0.0.0/0 | HTTP (package repos, Let's Encrypt) |
| Egress | 53 | UDP | 0.0.0.0/0 | DNS resolution |
| Egress | 53 | TCP | 0.0.0.0/0 | DNS over TCP (large responses) |
| Egress | 123 | UDP | 0.0.0.0/0 | NTP (time sync — critical for token TTLs) |
| Egress | 41641 | UDP | 0.0.0.0/0 | Tailscale WireGuard data plane |
| Egress | 3478 | UDP | 0.0.0.0/0 | Tailscale STUN (NAT traversal) |
| Ingress | — | — | — | **None. Zero inbound ports.** |

**Additional network controls:**

- **S3 Gateway VPC endpoint** (free) — keeps backup traffic on the AWS backbone, never traverses the public internet
- **No Elastic IP** needed — Tailscale MagicDNS provides stable addressing via the tailnet hostname

---

## Security Model

### Zero-Trust Network

- OpenBao listens on the **Tailscale interface only** (`100.x.y.z:8200`)
- Not reachable from the public internet, and not reachable from within the AWS VPC either
- **Tailscale ACLs** restrict which devices can reach port 8200 — not just "on the tailnet" but "authorized by ACL policy"
- **WireGuard encryption** in transit — TLS is disabled on the OpenBao listener since WireGuard already provides authenticated encryption

### Defense in Depth Layers

| Layer | Control | What It Prevents |
|-------|---------|-----------------|
| 1. Network | Zero inbound ports + Tailscale ACLs | Unauthorized network access |
| 2. Identity | IMDSv2 enforced, instance role scoped | SSRF credential theft, privilege escalation |
| 3. Encryption at rest | KMS for unseal key, separate KMS for backups, S3 SSE-KMS | Data exposure from stolen disks or snapshots |
| 4. Encryption in transit | WireGuard (Tailscale) | Network eavesdropping, MITM |
| 5. Audit | Every API call logged, shipped to CloudWatch | Undetected access, compliance gaps |
| 6. Backup integrity | Append-only from instance, versioned, MFA Delete option | Backup tampering by compromised instance |
| 7. Systemd hardening | ProtectSystem, ProtectHome, PrivateTmp, NoNewPrivileges, capability bounding | Container escape, local privilege escalation |

### KMS Key Policy vs IAM Policy

Understanding this split is critical for debugging access issues:

- **Key policy** = "who can use this key, under what conditions" — attached to the KMS key itself
- **IAM policy** = "what can this role do" — attached to the IAM role
- **Both must allow** for access to succeed (logical AND)
- Put **service-scoping** (`kms:ViaService`) on the key policy — "this key can only be used from EC2"
- Put **resource-scoping** (key ARN) on the IAM policy — "this role can only use this specific key"
- Do not duplicate conditions in both — it creates a maintenance burden with no additional security benefit

### Credential Lifecycle

```
┌─────────────┐     ┌──────────────┐     ┌─────────────────┐
│  Agent      │────>│  OpenBao     │────>│  AWS STS        │
│  (AppRole)  │     │  (Token)     │     │  (Temp Creds)   │
└─────────────┘     └──────────────┘     └─────────────────┘
  role_id +           TTL: 1h              TTL: 1h
  secret_id           max TTL: 4h          (non-revocable
  (24h, 10 uses)                            after issuance)
```

- **AppRole authentication:** `role_id` (identity, long-lived) + `secret_id` (credential, short-lived)
- **Tokens:** TTL 1h, max TTL 4h — agents must re-authenticate after expiry
- **Dynamic AWS credentials:** Generated via STS AssumeRole, TTL 1h. **Critical:** STS credentials cannot be revoked after issuance. Blast radius = the STS TTL window
- **secret_id:** TTL 24h, max 10 uses — limits the window for stolen credential replay
- **Token metadata:** `session_id`, `client`, `environment`, `task`, `repo` — enables audit correlation

---

## Operational Runbook

### Day 0: Initial Deployment

1. **Complete Phase 0 prerequisites** — AWS credentials, VPC IDs, Tailscale auth key (see `implementation-plan.md`)
2. **Bootstrap the state bucket:**
   ```bash
   cd vault-stack/bootstrap
   terraform init && terraform apply
   ```
3. **Update `backend.tf`** with your AWS account ID
4. **Run main Terraform:**
   ```bash
   cd vault-stack/terraform
   terraform init && terraform apply
   ```
5. **SSM into the instance:**
   ```bash
   aws ssm start-session --target <instance-id>
   ```
6. **Initialize OpenBao:**
   ```bash
   ./init-openbao.sh
   ```
   Save recovery keys securely (password manager, not plaintext files).
7. **Enable audit logging:**
   ```bash
   bao audit enable file file_path=/var/log/openbao/audit.log
   ```
8. **Create admin policy and user** — use the `policies/admin.hcl` template
9. **Revoke the root token:**
   ```bash
   ./teardown-root.sh
   ```
10. **Validate the deployment:**
    ```bash
    ./validate-init.sh
    ```
    All checks should pass (seal status, audit backend, policy list, health endpoint).

### Day 1: Verify Operations

- [ ] Check CloudWatch alarms are all in **OK** state
- [ ] Verify backup cron ran:
  ```bash
  aws s3 ls s3://openbao-raft-backups-<account-id>/snapshots/
  ```
- [ ] Confirm audit logs are shipping to CloudWatch — check the `/openbao/audit` log group
- [ ] Test a secret read/write cycle:
  ```bash
  bao kv put secret/test hello=world
  bao kv get secret/test
  bao kv delete secret/test
  ```

### Ongoing: Monitoring

| Task | Frequency | How |
|------|-----------|-----|
| Check alarm notifications | Continuous | Monitor `openbao-alerts` SNS topic |
| Review audit logs | Weekly | CloudWatch Insights query on `/openbao/audit` |
| Rotate secret_ids | Before 24h expiry | Re-issue via `bao write auth/approle/role/<role>/secret-id` |
| Verify backup integrity | Monthly | Download latest snapshot, test restore on a throwaway instance |
| Review IAM policies | Quarterly | Check for policy drift, unused permissions |
| Update OpenBao | As released | Follow release notes, test in staging first |

### Disaster Recovery

**RTO: ~15–20 minutes** for single-node recovery.

1. **Launch a new EC2 instance** (or `terraform apply` from scratch — Terraform state is in S3)
2. **Initialize the new OpenBao instance:**
   ```bash
   bao operator init -recovery-shares=5 -recovery-threshold=3
   ```
3. **Restore from the latest Raft snapshot:**
   ```bash
   # Find the latest snapshot
   aws s3 ls s3://openbao-raft-backups-<account-id>/snapshots/ --recursive | sort | tail -1

   # Download and restore
   aws s3 cp s3://openbao-raft-backups-<account-id>/snapshots/<latest>.snap /tmp/restore.snap
   bao operator raft snapshot restore /tmp/restore.snap
   ```
4. **Verify with validate-init.sh** — confirm seal status, policies, and audit backends
5. **Update Tailscale ACLs** if the node identity changed
6. **Notify consumers** to refresh their AppRole tokens (existing tokens will be invalid after restore if the token accessor changed)

---

## Cost Breakdown

### Minimal Setup (~$20/month)

| Service | Monthly Cost |
|---------|-------------|
| EC2 t4g.small (on-demand) | $12.41 |
| EBS 30 GB gp3 | $2.40 |
| KMS (2 keys: unseal + backup) | $2.00 |
| S3 (snapshots ~1 GB) | $0.02 |
| CloudWatch (basic alarms) | $3.00 |
| SNS (alert notifications) | $0.01 |
| S3 Gateway VPC Endpoint | Free |
| SSM Session Manager | Free |
| **Total** | **~$20** |

### Full Monitoring (~$41/month)

| Service | Additional Cost |
|---------|----------------|
| CloudWatch detailed monitoring (1-min) | $3.00 |
| CloudWatch Logs (audit ingestion) | $5–10 |
| CloudWatch custom metrics (2 metrics) | $3.00 |
| VPC Interface Endpoints (if private subnet) | $7–14 |
| **Total** | **~$41** |

### Cost Optimization

| Strategy | Savings | Trade-off |
|----------|---------|-----------|
| Reserved Instance (1-year, no upfront) | ~40% on EC2 | 1-year commitment |
| S3 Intelligent-Tiering | Automatic lifecycle | Small monitoring fee per object |
| CloudWatch Logs: aggressive retention | Proportional to retention reduction | Less historical data |
| Spot Instance | ~70% on EC2 | Instance can be interrupted (not recommended for secrets infrastructure) |

---

## OpenBao vs HashiCorp Vault

### Feature Parity

| Feature | Vault (OSS) | OpenBao | Notes |
|---------|-------------|---------|-------|
| KV v2 secrets engine | Yes | Yes | Identical API |
| Dynamic AWS credentials | Yes | Yes | Same STS integration |
| AppRole auth | Yes | Yes | Same configuration |
| Kubernetes auth | Yes | Yes | Same setup |
| Raft integrated storage | Yes | Yes | Same protocol, cross-compatible snapshots |
| AWS KMS auto-unseal | Yes | Yes | Same `seal "awskms"` config block |
| Transit encryption engine | Yes | Yes | Same API |
| Audit logging (file, syslog, socket) | Yes | Yes | Same format, same backends |
| PKI secrets engine | Yes | Yes | Same CA workflow |
| TOTP, SSH, Database engines | Yes | Yes | Same configuration |
| Namespaces | Enterprise only | No | Not needed for single-tenant deployments |
| Sentinel policies | Enterprise only | No | Use standard ACL policies |
| Performance replication | Enterprise only | Planned | Use Raft snapshots for DR in the interim |
| DR replication | Enterprise only | Planned | Same — Raft snapshots |
| Control groups | Enterprise only | No | Use policy path restrictions instead |

### Why OpenBao for This Project

1. **License:** MPL 2.0 (truly open source) vs BSL 1.1 (source-available with restrictions on competing products). MPL 2.0 has no usage restrictions
2. **Governance:** Linux Foundation stewardship with community-driven roadmap vs single-company control where licensing terms can change unilaterally
3. **Cost:** Free forever — no surprise licensing changes, no per-node fees, no feature gating
4. **Compatibility:** Drop-in replacement — same config files, same APIs, same client libraries, same Terraform providers
5. **Community:** Active development with contributions from multiple organizations, not dependent on one company's priorities

### Migration from Vault to OpenBao

If you have an existing Vault instance:

1. **Take a Raft snapshot:**
   ```bash
   vault operator raft snapshot save backup.snap
   ```
2. **Deploy OpenBao instance** using this project's Terraform (update the user-data script to install OpenBao instead of Vault)
3. **Initialize OpenBao:**
   ```bash
   bao operator init -recovery-shares=5 -recovery-threshold=3
   ```
4. **Restore the Vault snapshot into OpenBao:**
   ```bash
   bao operator raft snapshot restore backup.snap
   ```
5. **Update client environment variables:**
   ```bash
   # Old
   export VAULT_ADDR="https://vault.tailnet:8200"

   # New
   export BAO_ADDR="https://openbao.tailnet:8200"
   ```
   OpenBao also respects `VAULT_ADDR` for backward compatibility, but prefer `BAO_ADDR`.
6. **Update CLI usage:** `vault` commands become `bao` commands — all subcommands are identical:
   ```bash
   # Old                              # New
   vault kv get secret/foo     →      bao kv get secret/foo
   vault token lookup           →      bao token lookup
   vault operator raft ...      →      bao operator raft ...
   ```
7. **Update automation scripts:** Search and replace `vault` with `bao` in wrapper scripts, CI pipelines, and systemd units. The API paths (`/v1/secret/data/...`, `/v1/auth/approle/...`) remain identical.
