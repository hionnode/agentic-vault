# Agentic Vault

Secure credential management for agentic coding workflows using [OpenBao](https://openbao.org) (the open-source, MPL-2.0 Linux Foundation fork of HashiCorp Vault).

Agents authenticate via AppRole, receive short-lived scoped credentials, and every access is audited. No more `.env` files, no more pasting secrets into chat, no more long-lived AWS keys.

## Why This Exists

- **Agents need credentials.** Claude Code deploying infrastructure, n8n calling APIs, CI pipelines pushing containers — they all need secrets.
- **Current approaches are broken.** Credentials in `.env` files, pasted into chat prompts, or stored as long-lived IAM keys are insecure and unauditable.
- **Agents should get least-privilege, short-lived credentials** with full audit trails — the same standard we hold for human access.
- **No existing solution covers the agentic use case.** This project provides the integration patterns, infrastructure, and tooling to make OpenBao work natively with agentic coding tools.

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                   Tailscale Tailnet                  │
│                                                     │
│  ┌──────────┐  ┌──────────┐  ┌───────────────────┐ │
│  │ Dev      │  │ Homelab  │  │ Cloud Agents      │ │
│  │ Machine  │  │ K8s Nodes│  │ (CI, Lambda, etc.)│ │
│  └────┬─────┘  └────┬─────┘  └────────┬──────────┘ │
│       └──────────────┼─────────────────┘            │
│                      │                              │
│               ┌──────▼──────┐                       │
│               │ EC2 OpenBao │                       │
│               │  (Tailscale │                       │
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

Three integration modes, chosen by use case:

| Mode | When to Use | How It Works |
|------|------------|--------------|
| **Simple** | Local dev, short tasks, single client | Wrapper script injects credentials at session start |
| **Harness** | Multi-client, long tasks, CI/CD, unattended | `bao-agent` manages token lifecycle, session isolation, lease cleanup |
| **MCP** | Production agent workflows | Agent calls `read_secret`, `get_aws_credentials` as native tools |

## Quick Start

### Prerequisites

- AWS account with admin access
- [Tailscale](https://tailscale.com) account (free tier works)
- Terraform >= 1.10, AWS CLI v2, jq

### Deploy

1. **Bootstrap the Terraform state bucket:**
   ```bash
   cd vault-stack/bootstrap && terraform init && terraform apply
   ```

2. **Configure your variables:** Copy [`examples/terraform.tfvars.example`](examples/terraform.tfvars.example) to `vault-stack/terraform/terraform.tfvars` and fill in your values.

3. **Deploy the infrastructure:**
   ```bash
   cd vault-stack/terraform
   export TF_VAR_tailscale_authkey="tskey-auth-..."
   terraform init && terraform plan && terraform apply
   ```

4. **Initialize OpenBao:** SSM into the instance and run `scripts/init-openbao.sh`.

5. **Validate:** Run `scripts/validate-init.sh` to verify all components.

For the complete walkthrough, see the [implementation plan](implementation-plan.md) (Phase 0 through Phase 6).

## Repository Structure

```
agentic-vault/
├── vault-stack/
│   ├── terraform/           # EC2, IAM, KMS, S3, networking, monitoring
│   ├── scripts/             # Init, backup, teardown, validation
│   ├── config/              # OpenBao server configuration
│   └── bootstrap/           # Terraform state bucket setup
├── docs/
│   ├── openbao-aws-handbook.md    # Architecture deep dive & operations runbook
│   └── integration-patterns.md    # Auth patterns, secret access, integration modes
├── examples/
│   ├── terraform.tfvars.example   # Variable template for deployment
│   ├── vault-manifest-simple.yaml # Minimal project manifest
│   └── vault-manifest-full.yaml   # Full multi-client manifest
├── implementation-plan.md   # Complete build plan (Phases 0-9)
├── CLAUDE.md                # Claude Code project context
└── CONTRIBUTING.md
```

**Planned directories** (defined in the implementation plan, not yet built):

- `policies/` — OpenBao policy templates and generated policies
- `onboarding/` — Project onboarding/offboarding scripts
- `consumers/` — Integration configs for GitHub Actions, EKS, ECS, local dev
- `openbao-agent/` — `bao-agent` configs and templates (Harness Mode)
- `openbao-mcp-server/` — MCP server for native agent tool integration

## Documentation

| Document | Description |
|----------|-------------|
| [Implementation Plan](implementation-plan.md) | Complete build plan with phases, code, and operational procedures |
| [OpenBao AWS Handbook](docs/openbao-aws-handbook.md) | Architecture deep dive, security model, operational runbook, cost breakdown |
| [Integration Patterns](docs/integration-patterns.md) | Auth methods, secret access patterns, multi-consumer integration, failure modes |
| [OneCLI Integration](docs/onecli-integration.md) | Playbook for combining Agentic Vault with OneCLI's proxy-based credential injection |

## Cost

~$20/month for the minimal setup (EC2 t4g.small + KMS + S3 + CloudWatch basics). See the [cost breakdown](docs/openbao-aws-handbook.md) in the handbook for details.

## Status

| Agent | Mode | Auth | Status |
|---|---|---|---|
| Claude Code (local dev) | Simple | AppRole | Active |
| Claude Code (client work) | MCP | AppRole | Planned |
| n8n (homelab) | Harness | Kubernetes | Planned |
| GitHub Actions CI | Harness | AppRole | Planned |
| Content Pipeline | Simple | AppRole | Planned |
| CrewAI (homelab) | Harness | Kubernetes | Planned |

**Phase status:**

| Phase | Description | Status |
|-------|-------------|--------|
| 0-6 | Infrastructure (Terraform, EC2, OpenBao, backup, monitoring) | Built |
| 7 | Harness engineering layer (bao-agent, session isolation) | Planned |
| 8 | OpenBao MCP server (native agent tool integration) | Planned |
| 9 | High availability (multi-node Raft cluster) | Future |

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Contributions are especially welcome for the MCP server (Phase 8), policy templates, and consumer integrations.

## License

[MPL-2.0](LICENSE) — the same license as OpenBao itself.
