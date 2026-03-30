> This file provides project context for Claude Code sessions. If you're a human reader, start with [README.md](README.md).

# Agentic Vault

## What This Is

- OpenBao (open-source Vault fork, Linux Foundation) integration patterns for agentic coding tools (Claude Code, n8n, CrewAI, CI)
- Agents authenticate via AppRole, receive short-lived scoped credentials, every access is audited
- Implementation lives in `vault-stack/` — Terraform, scripts, and config for the full deployment

## Architecture

- Single-node OpenBao on EC2, Tailscale-only access, KMS auto-unseal, S3 backups (~$20/mo minimal)
- Three integration modes: Simple (wrapper scripts) → Harness (bao-agent mediated) → MCP (native agent tools)
- Build order: Phase 0 (prereqs) → Phases 1-6 (infra) → Phase 7 (harness) → Phase 8 (MCP server)
- CLI: `bao` (drop-in replacement for `vault` CLI, identical API surface)

## Security Model

- Least privilege at OpenBao policy path level — each agent reads only its own paths
- Short-lived credentials: token TTL 1h, AWS STS TTL 1h, secret_id TTL 24h
- Per-agent AppRole isolation; per-client-environment policy scoping
- Dynamic AWS credentials with explicit deny on privilege escalation and public access
- OpenBao is the ONLY credential source — no .env fallbacks, no static AWS keys
- Never work around OpenBao when it's down

## Naming Conventions

- AppRoles: `agent-{client}-{env}` (e.g., `agent-clientA-staging`)
- KV paths: `secret/agents/{name}/`, `secret/clients/{client}/{env}/`, `secret/personal/`
- Policies: `{client}-{env}-{engine}` (e.g., `clientA-staging-aws`)
- AWS dynamic roles: `{client}-{env}-deploy`
- Token display-name: `{agent-type}/{client}/{task}`
- Token metadata fields: session_id, client, environment, task, repo
- TTL defaults: token_ttl=1h, token_max_ttl=4h, secret_id_ttl=24h, secret_id_num_uses=10

## Current Status

| Agent | Mode | Auth | Status |
|---|---|---|---|
| Claude Code (local dev) | Simple | AppRole | Active |
| Claude Code (client work) | MCP | AppRole | Planned |
| n8n (homelab) | Harness | Kubernetes | Planned |
| GitHub Actions CI | Harness | AppRole | Planned |
| Content Pipeline | Simple | AppRole | Planned |
| CrewAI (homelab) | Harness | Kubernetes | Planned |

## Mode Selection

- **Simple Mode:** Local dev, <1h tasks, single client, actively supervised. Wrapper script injects creds at session start.
- **Harness Mode:** Multi-client agency work, >1h tasks, unattended runs, CI/CD. bao-agent manages token lifecycle, session isolation, lease cleanup.
- **MCP Mode:** Production agent workflows. Agent calls `read_secret`, `get_aws_credentials` as native tools. Credential-aware, session-policy-enforced.

## Known Limitations

- **Single-node OpenBao:** 15-20min RTO on failure. Dev/POC grade — HA (Phase 9) required for SLA-bound agency work.
- **STS revocation gap:** AWS STS credentials cannot be revoked after issuance. Blast radius = STS TTL window. Use short TTLs (15-30min) for prod roles.
- **Secret_id rotation is manual:** Automation planned but not built. GHA secret_id is inherently static — mitigate with short token TTL.
- **Tailscale is the sole network perimeter:** Defense-in-depth (mTLS on OpenBao listener) planned but not yet implemented.
- **Token/STS TTL alignment:** A 4h OpenBao token can generate multiple 4h STS credential pairs. Align TTLs and monitor for mismatches.
- **No network egress controls** on agent hosts — a compromised agent can exfiltrate fetched secrets.

## Key Don'ts

- Never commit .env files, credentials, or OpenBao tokens
- Never create long-lived IAM access keys
- Never use wildcard OpenBao policies unless unavoidable
- Never bypass OpenBao by pasting credentials into prompts or chat
- Never skip the IAM deny block (no PutBucketPolicy, no iam:Create*, no AuthorizeSecurityGroupIngress)
- Never expose OpenBao outside Tailscale without mTLS

## Documentation

- **`docs/openbao-aws-handbook.md`** — Architecture & operations handbook: AWS services deep dive, security model, operational runbook, cost breakdown, OpenBao vs Vault comparison
- **`docs/integration-patterns.md`** — Full reference: auth patterns (AppRole, K8s, Token), secret access (KV v2, dynamic AWS), wrapper scripts, multi-consumer integration (GitHub Actions, EKS, ECS), harness mode (bao-agent, session identity, lease tracking, credential gating), MCP server design, guardrails, failure modes
- **`implementation-plan.md`** — Infrastructure build plan: Terraform, EC2 provisioning, OpenBao config, backup/DR, Phase 7 harness engineering, Phase 8 MCP server implementation
