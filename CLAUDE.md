# Agentic Vault

## What This Is

- Vault integration patterns for agentic coding tools (Claude Code, n8n, CrewAI, CI)
- Agents authenticate via AppRole, receive short-lived scoped credentials, every access is audited
- Design/documentation repo; implementation will live in a separate vault-stack repo

## Architecture

- Single-node Vault on EC2, Tailscale-only access, KMS auto-unseal, S3 backups (~$12-15/mo realistic)
- Three integration modes: Simple (wrapper scripts) → Harness (vault-agent mediated) → MCP (native agent tools)
- Build order: Phases 1-6 (infra) → Phase 7 (harness) → Phase 8 (MCP server)

## Security Model

- Least privilege at Vault policy path level — each agent reads only its own paths
- Short-lived credentials: token TTL 1h, AWS STS TTL 1h, secret_id TTL 24h
- Per-agent AppRole isolation; per-client-environment policy scoping
- Dynamic AWS credentials with explicit deny on privilege escalation and public access
- Vault is the ONLY credential source — no .env fallbacks, no static AWS keys
- Never work around Vault when it's down

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
- **Harness Mode:** Multi-client agency work, >1h tasks, unattended runs, CI/CD. vault-agent manages token lifecycle, session isolation, lease cleanup.
- **MCP Mode:** Production agent workflows. Agent calls `read_secret`, `get_aws_credentials` as native tools. Credential-aware, session-policy-enforced.

## Known Limitations

- **Single-node Vault:** 15-20min RTO on failure. Dev/POC grade — HA (Phase 9) required for SLA-bound agency work.
- **STS revocation gap:** AWS STS credentials cannot be revoked after issuance. Blast radius = STS TTL window. Use short TTLs (15-30min) for prod roles.
- **Secret_id rotation is manual:** Automation planned but not built. GHA secret_id is inherently static — mitigate with short token TTL.
- **Tailscale is the sole network perimeter:** Defense-in-depth (mTLS on Vault listener) planned but not yet implemented.
- **Token/STS TTL alignment:** A 4h Vault token can generate multiple 4h STS credential pairs. Align TTLs and monitor for mismatches.
- **No network egress controls** on agent hosts — a compromised agent can exfiltrate fetched secrets.

## Key Don'ts

- Never commit .env files, credentials, or Vault tokens
- Never create long-lived IAM access keys
- Never use wildcard Vault policies unless unavoidable
- Never bypass Vault by pasting credentials into prompts or chat
- Never skip the IAM deny block (no PutBucketPolicy, no iam:Create*, no AuthorizeSecurityGroupIngress)
- Never expose Vault outside Tailscale without mTLS

## Documentation

- **`docs/integration-patterns.md`** — Full reference: auth patterns (AppRole, K8s, Token), secret access (KV v2, dynamic AWS), wrapper scripts, multi-consumer integration (GitHub Actions, EKS, ECS), harness mode (vault-agent, session identity, lease tracking, credential gating), MCP server design, guardrails, failure modes
- **`implementation-plan.md`** — Infrastructure build plan: Terraform, EC2 provisioning, Vault config, backup/DR, Phase 7 harness engineering, Phase 8 MCP server implementation
