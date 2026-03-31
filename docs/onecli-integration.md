# Integrating Agentic Vault with OneCLI

A playbook for using OpenBao (Agentic Vault) as the credential backend and [OneCLI](https://onecli.sh) as the agent-facing proxy layer. Together they provide defense-in-depth: short-lived, dynamically generated credentials that agents never directly hold.

## Why Combine Them

Agentic Vault and OneCLI solve different halves of the agent credential problem:

**Agentic Vault (OpenBao) handles credential lifecycle:**
- Generates short-lived AWS STS tokens, database credentials, certificates
- Enforces per-client, per-environment policy isolation
- Manages lease TTLs and automatic expiry
- Audits every credential issuance

**OneCLI handles credential usage:**
- Agents never see raw API keys — the proxy injects credentials at the HTTP layer
- Blocks dangerous operations per agent (e.g., no DELETE on production endpoints)
- Rate-limits API calls per agent per endpoint
- Audits every API request the agent makes

**Neither alone covers both.** OpenBao loses control after credential issuance — a compromised agent can exfiltrate fetched secrets. OneCLI can't generate dynamic credentials — it only injects static keys. Combined, credentials are both short-lived *and* invisible to the agent.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Agent Host                               │
│                                                                 │
│  ┌──────────────────┐     ┌──────────────────────────────────┐ │
│  │   Agent           │     │   OneCLI Gateway (:10255)        │ │
│  │   (Claude Code,   │────▶│                                  │ │
│  │    n8n, etc.)     │     │   1. Authenticate agent          │ │
│  │                   │     │   2. Evaluate rules (block/rate) │ │
│  │  HTTP_PROXY=      │     │   3. Inject credentials          │ │
│  │  localhost:10255  │     │   4. Forward to target API       │ │
│  └──────────────────┘     └───────────┬──────────────────────┘ │
│                                       │                         │
└───────────────────────────────────────┼─────────────────────────┘
                                        │ HTTPS
                                        ▼
                                 ┌──────────────┐
                                 │  Target APIs  │
                                 │  (AWS, Slack, │
                                 │   GitHub, …)  │
                                 └──────────────┘

  ┌──────────────────────────────────────────────────────────────┐
  │  Credential Sync (cron / session launcher)                   │
  │                                                              │
  │  bao read aws/creds/agent-deploy ──▶ onecli secrets update  │
  │  bao read secret/data/agents/…   ──▶ onecli secrets update  │
  │                                                              │
  │  Runs on TTL-aware schedule (before credential expiry)       │
  └──────────────┬───────────────────────────────┬───────────────┘
                 │                               │
                 ▼                               ▼
    ┌────────────────────┐          ┌────────────────────────┐
    │  OpenBao (Agentic  │          │  OneCLI Secret Store   │
    │  Vault) on EC2     │          │  (AES-256-GCM)         │
    │  via Tailscale     │          │                        │
    │                    │          │  Receives credentials   │
    │  Generates:        │          │  from sync, injects    │
    │  - STS tokens      │          │  into proxied requests │
    │  - KV secrets      │          │                        │
    │  - DB credentials  │          │                        │
    └────────────────────┘          └────────────────────────┘
```

## What Each Layer Provides

| Capability | Agentic Vault | OneCLI | Combined |
|------------|:---:|:---:|:---:|
| Dynamic credential generation (AWS STS, DB) | Yes | No | Yes |
| Credential TTL / automatic expiry | Yes | No | Yes |
| Agent never sees raw credentials | No | Yes | Yes |
| Per-request endpoint blocking | No | Yes | Yes |
| Per-request rate limiting | No | Yes | Yes |
| Multi-client policy isolation | Yes | Basic | Yes |
| Non-HTTP credential use (SSH, DB, gRPC) | Yes | No | Partial |
| Audit of credential issuance | Yes | No | Yes |
| Audit of credential usage | No | Yes | Yes |
| Credential rotation (transparent) | No | Yes | Yes |

## Integration Pattern: Credential Sync

The primary integration today is a sync process that fetches credentials from OpenBao and pushes them into OneCLI's secret store. This runs as part of the session launcher (Harness Mode) or as a cron job.

### Sync Script

```bash
#!/usr/bin/env bash
set -euo pipefail

# sync-credentials.sh — Fetch from OpenBao, push to OneCLI
# Run this at session start and on a TTL-aware schedule.

BAO_ADDR="${BAO_ADDR:-http://localhost:8200}"
ONECLI_URL="${ONECLI_URL:-http://localhost:10254}"
CLIENT="${1:?Usage: sync-credentials.sh <client> <env>}"
ENV="${2:?Usage: sync-credentials.sh <client> <env>}"

echo "Syncing credentials for ${CLIENT}/${ENV}..."

# --- AWS STS credentials ---
# Generate short-lived STS tokens from OpenBao
AWS_CREDS=$(bao read -format=json "aws/creds/${CLIENT}-${ENV}-deploy")
AWS_ACCESS_KEY=$(echo "$AWS_CREDS" | jq -r '.data.access_key')
AWS_SECRET_KEY=$(echo "$AWS_CREDS" | jq -r '.data.secret_key')
AWS_SESSION_TOKEN=$(echo "$AWS_CREDS" | jq -r '.data.security_token')
LEASE_DURATION=$(echo "$AWS_CREDS" | jq -r '.lease_duration')

# Push to OneCLI as a secret for AWS API endpoints
# OneCLI will inject these as headers when the agent calls AWS APIs
onecli secrets update aws-${CLIENT}-${ENV} \
  --value "${AWS_ACCESS_KEY}:${AWS_SECRET_KEY}:${AWS_SESSION_TOKEN}" \
  --host "*.amazonaws.com" \
  --quiet

echo "  AWS STS credentials synced (TTL: ${LEASE_DURATION}s)"

# --- Static KV secrets ---
# Sync API keys that the agent needs for HTTP calls
SECRETS=$(bao kv list -format=json "secret/clients/${CLIENT}/${ENV}/" 2>/dev/null || echo "[]")

for SECRET_NAME in $(echo "$SECRETS" | jq -r '.[]'); do
  SECRET_VALUE=$(bao kv get -format=json "secret/clients/${CLIENT}/${ENV}/${SECRET_NAME}" \
    | jq -r '.data.data.value')

  # Map secret names to OneCLI host patterns
  # This mapping is project-specific — customize for your secrets
  case "$SECRET_NAME" in
    github-token)
      onecli secrets update "github-${CLIENT}-${ENV}" \
        --value "$SECRET_VALUE" \
        --host "api.github.com" \
        --quiet
      ;;
    slack-token)
      onecli secrets update "slack-${CLIENT}-${ENV}" \
        --value "$SECRET_VALUE" \
        --host "slack.com" \
        --quiet
      ;;
    openai-api-key)
      onecli secrets update "openai-${CLIENT}-${ENV}" \
        --value "$SECRET_VALUE" \
        --host "api.openai.com" \
        --quiet
      ;;
    *)
      echo "  Skipping unmapped secret: ${SECRET_NAME}"
      ;;
  esac
done

echo "Sync complete."

# --- Schedule next sync ---
# Re-run before the shortest credential TTL expires.
# For STS with 1h TTL, sync every 50 minutes.
echo "Next sync should run before TTL expiry (${LEASE_DURATION}s)."
```

### TTL-Aware Refresh

STS credentials expire. The sync must re-run before the shortest TTL in the set:

```bash
# In the session launcher or cron:
# Sync every 50 minutes for 1h TTL credentials
*/50 * * * * /path/to/sync-credentials.sh clientA staging >> /var/log/credential-sync.log 2>&1
```

For Harness Mode (bao-agent), the agent's template rendering already handles TTL-aware refresh. The sync script reads from bao-agent's rendered output instead of calling OpenBao directly:

```bash
# Read from bao-agent's rendered credentials instead of hitting OpenBao API
source /home/user/.openbao/rendered/agent.env
onecli secrets update aws-${CLIENT}-${ENV} \
  --value "${AWS_ACCESS_KEY_ID}:${AWS_SECRET_ACCESS_KEY}:${AWS_SESSION_TOKEN}" \
  --host "*.amazonaws.com" \
  --quiet
```

## Integration Pattern: Direct Vault Backend (Future)

OneCLI's roadmap includes HashiCorp Vault as a secrets backend. Since OpenBao is API-compatible with Vault, this would allow OneCLI to query OpenBao directly on each proxied request — no sync script needed.

When available, the architecture simplifies:

```
Agent ──▶ OneCLI Proxy ──▶ Target API
               │
               │ (on each request, fetch credential)
               ▼
          OpenBao (via Tailscale)
```

This eliminates sync lag and the credential-in-two-places problem. Watch [OneCLI's roadmap](https://www.onecli.sh/docs) for availability.

## Setup Guide

### Prerequisites

- Running OpenBao instance (Agentic Vault Phases 0-6 complete)
- Docker installed on the agent host
- OneCLI CLI installed: `curl -fsSL onecli.sh/cli/install | sh`
- Network access: agent host can reach both OpenBao (via Tailscale) and OneCLI (localhost)

### 1. Deploy OneCLI

```bash
docker run -d \
  --name onecli \
  -p 10254:10254 \
  -p 10255:10255 \
  -v onecli-data:/app/data \
  ghcr.io/onecli/onecli:latest
```

### 2. Create an Agent Identity in OneCLI

```bash
# Create an agent for Claude Code
onecli agents create \
  --name "claude-code" \
  --description "Claude Code agent for client work"

# Note the access token — agents use this in Proxy-Authorization header
```

### 3. Configure OneCLI Rules

Set up guardrails for the agent:

```bash
# Block destructive operations on production APIs
onecli rules create \
  --name "block-prod-deletes" \
  --host "*.amazonaws.com" \
  --method DELETE \
  --action block

# Rate-limit Slack API calls
onecli rules create \
  --name "slack-rate-limit" \
  --host "slack.com" \
  --path "/api/chat.postMessage" \
  --action rate-limit \
  --rate "10/hour"

# Block IAM privilege escalation attempts
onecli rules create \
  --name "block-iam-escalation" \
  --host "iam.amazonaws.com" \
  --action block
```

### 4. Run the Initial Credential Sync

```bash
# Authenticate to OpenBao
export BAO_ADDR="http://openbao:8200"  # via Tailscale MagicDNS
export BAO_TOKEN=$(bao write -field=token auth/approle/login \
  role_id="$(cat ~/.openbao/role-id)" \
  secret_id="$(cat ~/.openbao/secret-id)")

# Sync credentials
./sync-credentials.sh clientA staging
```

### 5. Configure the Agent

```bash
# Set proxy environment variables for the agent session
export HTTP_PROXY="http://localhost:10255"
export HTTPS_PROXY="http://localhost:10255"

# Trust OneCLI's CA certificate (required for HTTPS interception)
export NODE_EXTRA_CA_CERTS="/path/to/onecli-ca.pem"

# Launch Claude Code (or any agent)
claude
```

## Example: Claude Code Session with Both Layers

A complete session startup combining Agentic Vault + OneCLI:

```bash
#!/usr/bin/env bash
# session-launcher.sh — Start a Claude Code session with full credential stack

set -euo pipefail

CLIENT="${1:?Usage: session-launcher.sh <client> <env>}"
ENV="${2:?Usage: session-launcher.sh <client> <env>}"
SESSION_ID=$(uuidgen)

echo "Starting session ${SESSION_ID} for ${CLIENT}/${ENV}"

# 1. Authenticate to OpenBao via AppRole
export BAO_ADDR="http://openbao:8200"
export BAO_TOKEN=$(bao write -field=token auth/approle/login \
  role_id="$(cat ~/.openbao/roles/${CLIENT}-${ENV}/role-id)" \
  secret_id="$(cat ~/.openbao/roles/${CLIENT}-${ENV}/secret-id)")

# 2. Create a session-scoped token with metadata
SESSION_TOKEN=$(bao token create \
  -policy="agent-aws-${CLIENT}-${ENV}" \
  -ttl=4h \
  -display-name="claude-code/${CLIENT}/${SESSION_ID}" \
  -metadata="session_id=${SESSION_ID}" \
  -metadata="client=${CLIENT}" \
  -metadata="environment=${ENV}" \
  -field=token)
export BAO_TOKEN="$SESSION_TOKEN"

# 3. Sync credentials from OpenBao → OneCLI
./sync-credentials.sh "$CLIENT" "$ENV"

# 4. Configure agent to use OneCLI proxy
export HTTP_PROXY="http://localhost:10255"
export HTTPS_PROXY="http://localhost:10255"

# 5. Schedule credential refresh (background)
while true; do
  sleep 3000  # 50 minutes
  ./sync-credentials.sh "$CLIENT" "$ENV" 2>&1 | logger -t credential-sync
done &
SYNC_PID=$!

# 6. Launch Claude Code
claude

# 7. Cleanup on exit
kill "$SYNC_PID" 2>/dev/null
bao token revoke -self
echo "Session ${SESSION_ID} ended."
```

## Security Model: Defense-in-Depth

| Threat | Agentic Vault Only | OneCLI Only | Both |
|--------|:---:|:---:|:---:|
| Agent exfiltrates API keys from memory | Mitigated (short TTL) | Prevented (agent never has keys) | Prevented |
| Agent calls dangerous endpoint (e.g., DELETE production) | Not prevented | Blocked by rules | Blocked by rules |
| Agent makes excessive API calls | Not prevented | Rate-limited | Rate-limited |
| Compromised agent generates unlimited STS tokens | Prevented (policy scoping) | Not applicable | Prevented |
| Credential used after agent session ends | Expires (TTL) | Can be revoked in OneCLI | Both |
| Cross-client credential access | Prevented (AppRole isolation) | Basic (per-agent secrets) | Prevented |
| Audit of what credentials were issued | Yes | No | Yes |
| Audit of what credentials were used for | No | Yes | Yes |

## Limitations and Tradeoffs

**Sync lag.** There's a window between credential generation in OpenBao and availability in OneCLI. For STS credentials with 1h TTL, syncing every 50 minutes means up to 50 minutes of lag for rotation. The direct vault backend (future) eliminates this.

**Credential in two places.** During sync, the credential exists in both OpenBao's lease store and OneCLI's encrypted store. This expands the attack surface slightly. Mitigate with short TTLs and encrypted storage on both sides.

**Non-HTTP traffic.** OneCLI only proxies HTTP. For SSH, database connections, gRPC, or other protocols, the agent still needs direct credential access from OpenBao. The combined model provides defense-in-depth for HTTP APIs only.

**Operational complexity.** Running both adds a Docker container, a sync script, and CA certificate management. This is justified for multi-client agency work or unattended agent runs, but overkill for supervised local dev (use Agentic Vault's Simple Mode instead).

**OneCLI's vault backend roadmap.** The sync pattern is a bridge. When OneCLI ships native Vault/OpenBao backend support, the sync script becomes unnecessary and the architecture simplifies significantly.

## When to Use Which

| Scenario | Recommendation |
|----------|---------------|
| Solo local dev, short tasks | Agentic Vault Simple Mode only |
| Multi-client agency work, HTTP-heavy | Both (full stack) |
| Infrastructure-only tasks (Terraform, AWS CLI) | Agentic Vault only (non-HTTP) |
| API-only tasks (calling SaaS APIs) | OneCLI only (simpler) |
| Unattended agent runs with guardrails | Both (full stack) |
| Quick prototype / evaluation | OneCLI only (faster setup) |
