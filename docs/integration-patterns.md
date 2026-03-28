# Agentic Vault — Integration Patterns Reference

## The Problem

Agentic coding tools (Claude Code, Cursor, Cline, Aider, custom smolagents pipelines) need credentials to do useful work — AWS keys to provision infra, database passwords to run migrations, API tokens to deploy services. Today, most developers handle this in one of these ways:

- `.env` files sitting in project roots, often accidentally committed
- Pasting credentials directly into agent prompts or chat interfaces
- Long-lived IAM access keys with overly broad permissions
- Letting the agent itself create credentials with no audit trail

Every one of these is a security incident waiting to happen. The agent doesn't know the difference between provisioning an S3 bucket and making it public, and the credentials it holds determine the blast radius when things go wrong.

OpenBao changes the equation: agents authenticate, receive short-lived scoped credentials, every access is logged, and the credentials auto-expire. The agent can still make mistakes, but the damage is time-bounded and auditable.

---

## Agent Authentication Patterns

### Pattern 1: AppRole (recommended for most agent workflows)

AppRole is OpenBao's machine-oriented auth method. Each agent type gets a `role_id` (public, identifies the role) and a `secret_id` (private, proves identity). Together they produce a short-lived OpenBao token.

**How it works in practice:**

```
Agent starts up
    │
    ▼
Reads role_id from config (not sensitive)
    │
    ▼
Reads secret_id from secure location
(env var injected by wrapper, or fetched from a bootstrap source)
    │
    ▼
POST /v1/auth/approle/login
{ "role_id": "...", "secret_id": "..." }
    │
    ▼
Receives OpenBao token (TTL: 1h)
    │
    ▼
Uses token to read secrets as needed
    │
    ▼
Token expires automatically after TTL
```

**Setup per agent type:**

```bash
# Create the AppRole
bao write auth/approle/role/claude-code-agent \
  token_ttl=1h \
  token_max_ttl=4h \
  secret_id_ttl=24h \
  secret_id_num_uses=10 \
  token_policies="agent-aws,agent-kv-readonly" \
  bind_secret_id=true

# Get the role_id (store in agent config)
bao read auth/approle/role/claude-code-agent/role-id

# Generate a secret_id (rotate daily, inject into agent env)
bao write -f auth/approle/role/claude-code-agent/secret-id
```

**Key security properties:**

- `secret_id_num_uses=10` — the secret_id is consumed after 10 logins, then a new one must be generated. Limits replay window.
- `token_ttl=1h` — even if the token leaks, it's dead in an hour.
- `secret_id_ttl=24h` — forces daily rotation of the bootstrap credential.

**TTL alignment:** Ensure `token_max_ttl` aligns with `max_sts_ttl` on your AWS roles. A 4h OpenBao token can generate multiple sets of 4h STS credentials across its lifetime — each set valid independently. For tighter control, set `max_sts_ttl` equal to or shorter than `token_ttl`.

### Pattern 2: Kubernetes Auth (for agents running in your homelab cluster)

If agents run as pods in your Talos cluster, they can authenticate to OpenBao using their Kubernetes service account token. No secret_id to manage — the pod's identity IS the credential.

```
Pod starts with ServiceAccount "agent-deploy"
    │
    ▼
Reads SA token from /var/run/secrets/kubernetes.io/serviceaccount/token
    │
    ▼
POST /v1/auth/kubernetes/login
{ "role": "agent-deploy", "jwt": "<sa-token>" }
    │
    ▼
OpenBao verifies token with K8s API
    │
    ▼
Returns OpenBao token scoped to agent-deploy policy
```

Requires configuring OpenBao's Kubernetes auth method to trust your Talos cluster's API server. Works well for n8n workflows, CrewAI agents, or any containerised agent pipeline running on the homelab.

### Pattern 3: Token Auth (for quick dev/testing only)

For local development and quick iteration, generate a token with a short TTL and pass it to the agent:

```bash
bao token create -policy=agent-aws -ttl=2h -use-limit=50
```

Inject into the agent's environment: `export BAO_TOKEN=hvs.xxx`

This is acceptable for local dev sessions where you're actively supervising the agent. Not suitable for unattended or production workflows — use AppRole instead.

---

## Secret Access Patterns for Agents

### Static Secrets (KV v2)

For API keys, database passwords, and third-party tokens that don't change frequently:

```bash
# Agent reads a secret
bao kv get -mount=secret agents/deploy/database-url
```

**Organise KV paths by agent and environment:**

```
secret/
├── agents/
│   ├── claude-code/
│   │   ├── github-token
│   │   ├── vercel-token
│   │   └── cloudflare-api-key
│   ├── n8n/
│   │   ├── slack-webhook
│   │   └── openai-api-key
│   └── ci/
│       ├── docker-registry-creds
│       └── npm-token
├── homelab/
│   ├── argocd-admin
│   └── grafana-admin
└── clients/
    └── <client-name>/
        └── aws-account-id
```

Each agent's policy only grants read access to its own path. Claude Code cannot read n8n's secrets. The CI agent cannot read client credentials. Principle of least privilege at the path level.

### Dynamic AWS Credentials (the high-value pattern)

This is where OpenBao goes from "password manager" to security architecture. Instead of storing static AWS access keys, OpenBao generates ephemeral IAM credentials on demand.

**Setup:**

```bash
# Enable AWS secrets engine
bao secrets enable aws

# Configure with IAM user that can create STS tokens
bao write aws/config/root \
  access_key=AKIA... \
  secret_key=... \
  region=ap-south-1

# Define a role with a locked-down IAM policy
bao write aws/roles/agent-deploy \
  credential_type=iam_user \
  default_sts_ttl=1h \
  max_sts_ttl=4h \
  policy_document=-<<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:RunInstances",
        "ec2:DescribeInstances",
        "ec2:TerminateInstances",
        "s3:CreateBucket",
        "s3:PutObject",
        "s3:GetObject"
      ],
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "aws:RequestedRegion": "ap-south-1"
        }
      }
    },
    {
      "Effect": "Deny",
      "Action": [
        "s3:PutBucketPolicy",
        "s3:PutBucketAcl",
        "s3:PutObjectAcl",
        "ec2:AuthorizeSecurityGroupIngress",
        "iam:CreateUser",
        "iam:CreateAccessKey",
        "iam:AttachUserPolicy",
        "iam:AttachRolePolicy",
        "organizations:*",
        "account:*",
        "s3:DeleteBucket",
        "s3:DeleteObject",
        "s3:DeleteBucketPolicy",
        "ec2:DeleteVolume",
        "ec2:DeleteSecurityGroup",
        "ec2:RevokeSecurityGroupEgress",
        "rds:DeleteDBInstance",
        "rds:ModifyDBCluster",
        "lambda:DeleteFunction",
        "lambda:UpdateFunctionCode",
        "dynamodb:DeleteTable",
        "logs:DeleteLogGroup",
        "cloudtrail:DeleteTrail",
        "cloudtrail:StopLogging",
        "kms:DisableKey",
        "kms:ScheduleKeyDeletion",
        "route53:DeleteHostedZone",
        "cloudformation:DeleteStack",
        "sns:Publish",
        "sqs:SendMessage",
        "secretsmanager:*",
        "servicequotas:*"
      ],
      "Resource": "*"
    }
  ]
}
EOF
```

> **Production recommendation:** The example above uses `credential_type=iam_user` for simplicity. For production, prefer `credential_type=assumed_role` with a pre-created IAM role — it avoids creating temporary IAM users and has a cleaner security footprint:
> ```bash
> bao write aws/roles/agent-deploy \
>   credential_type=assumed_role \
>   role_arns="arn:aws:iam::<account-id>:role/agent-deploy-role" \
>   default_sts_ttl=1h \
>   max_sts_ttl=4h
> ```

**Agent usage:**

```bash
# Agent requests temporary AWS creds
bao read aws/creds/agent-deploy

# Returns:
# access_key     ASIA...
# secret_key     ...
# security_token ...
# lease_duration 1h
```

**What the deny block prevents:**

- Agent cannot make S3 buckets public (no PutBucketPolicy/PutBucketAcl)
- Agent cannot open security groups to the internet (no AuthorizeSecurityGroupIngress with 0.0.0.0/0 is handled by SCP or the deny)
- Agent cannot create new IAM users or access keys (no privilege escalation)
- Agent cannot modify IAM policies (cannot grant itself more permissions)
- Agent is locked to ap-south-1 (cannot spin up resources in forgotten regions)
- Credentials expire in 1 hour regardless

Even if the agent hallucinates a Terraform config that tries to do something dangerous, the IAM policy says no. The agent's capability ceiling is defined by OpenBao, not by the agent's judgment.

---

## Simple Mode: Wrapper Scripts for Agent Integration

Agents typically need credentials injected into their environment. The patterns below work well for solo local dev where you're actively supervising the agent. For unattended, multi-client, or production-grade workflows, see **Harness Mode** (Phase 7/8 patterns) below.

> **When to use Simple Mode:** Local dev sessions, quick prototyping, single-client work, actively supervised agents.
> **When to upgrade to Harness Mode:** Multi-client agency work, unattended agent runs, CI/CD pipelines, any scenario where the agent spawns sub-processes or runs longer than 1 hour.

### Claude Code Wrapper

```bash
#!/bin/bash
# claude-code-openbao.sh — wraps Claude Code with OpenBao-sourced credentials

set -euo pipefail

BAO_ADDR="${BAO_ADDR:-http://openbao:8200}"
export BAO_ADDR

# Validate prerequisites
: "${CLAUDE_CODE_ROLE_ID:?Error: CLAUDE_CODE_ROLE_ID not set}"
: "${CLAUDE_CODE_SECRET_ID:?Error: CLAUDE_CODE_SECRET_ID not set}"
command -v bao >/dev/null 2>&1 || { echo "Error: bao CLI not found in PATH" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "Error: jq not found in PATH" >&2; exit 1; }

# Verify OpenBao is reachable
if ! bao status >/dev/null 2>&1; then
  echo "Error: OpenBao at $BAO_ADDR is unreachable" >&2
  exit 1
fi

# Authenticate via AppRole with retry
retry_count=0
until BAO_TOKEN=$(bao write -field=token auth/approle/login \
  role_id="$CLAUDE_CODE_ROLE_ID" \
  secret_id="$CLAUDE_CODE_SECRET_ID"); do
  retry_count=$((retry_count + 1))
  if [ $retry_count -ge 3 ]; then
    echo "Error: Failed to authenticate after 3 attempts" >&2
    exit 1
  fi
  echo "Auth attempt $retry_count failed, retrying in 2s..." >&2
  sleep 2
done
export BAO_TOKEN

# Fetch AWS creds from dynamic secrets engine
AWS_CREDS=$(bao read -format=json aws/creds/agent-deploy)
export AWS_ACCESS_KEY_ID=$(echo "$AWS_CREDS" | jq -r '.data.access_key')
export AWS_SECRET_ACCESS_KEY=$(echo "$AWS_CREDS" | jq -r '.data.secret_key')
export AWS_SESSION_TOKEN=$(echo "$AWS_CREDS" | jq -r '.data.security_token')

# Fetch any static secrets needed
export GITHUB_TOKEN=$(bao kv get -field=value secret/agents/claude-code/github-token)
export CLOUDFLARE_API_TOKEN=$(bao kv get -field=value secret/agents/claude-code/cloudflare-api-key)

# Cleanup on exit
cleanup() {
  if BAO_TOKEN="$BAO_TOKEN" bao token revoke -self 2>/dev/null; then
    echo "[cleanup] OpenBao token revoked" >&2
  else
    echo "[cleanup] Warning: token revocation failed" >&2
  fi
}
trap cleanup EXIT INT TERM

# Launch Claude Code with credentials in environment
claude "$@"
```

### Claude Code Hooks Integration

If using Claude Code hooks (`.claude/hooks/`), the PreToolUse or PostToolUse hooks can gate credential access:

```bash
# .claude/hooks/pre-tool-use.sh
# Runs before any tool execution in Claude Code

# Refresh OpenBao token if expired
if ! bao token lookup > /dev/null 2>&1; then
  BAO_TOKEN=$(bao write -field=token auth/approle/login \
    role_id="$CLAUDE_CODE_ROLE_ID" \
    secret_id="$CLAUDE_CODE_SECRET_ID")
  export BAO_TOKEN
fi

# Refresh AWS creds if within 10 min of expiry
# (implement TTL check logic based on lease duration)
```

### n8n / Workflow Engine Integration

For n8n running on the homelab cluster, use the Kubernetes auth pattern. The n8n pod authenticates with its service account and fetches secrets at workflow execution time, either via n8n's HTTP Request node calling the OpenBao API directly, or via an init container that populates a shared volume with secrets.

### CI/CD (GitHub Actions)

For GitHub Actions or similar CI that runs outside your tailnet:

1. CI runner authenticates to OpenBao via AppRole (secret_id stored as a GitHub Actions secret — this is the one static secret you can't avoid)
2. CI requests scoped credentials from OpenBao for the specific deployment
3. Credentials are used in the workflow and expire after the run

Alternatively, if you self-host runners on your homelab cluster, they can use Kubernetes auth and stay fully within the tailnet.

---

## Guardrails: What OpenBao Can and Cannot Prevent

### What OpenBao handles well

| Threat | How OpenBao mitigates |
|---|---|
| Agent uses overly broad AWS creds | Dynamic creds with deny-list IAM policy |
| Credential leak in agent output/logs | Creds expire in 1h, blast radius is time-bounded |
| No audit trail of secret access | Every read/write logged with accessor identity |
| Shared credentials across agents | Each agent gets unique AppRole and policy |
| Secrets sprawl in .env files | Secrets fetched at runtime, never touch disk |
| Agent provisions in wrong region | IAM condition restricts to allowed regions |
| Agent escalates its own permissions | Deny on iam:Create*, iam:Attach* actions |

### What OpenBao does NOT handle

| Threat | Why OpenBao can't help | What to do instead |
|---|---|---|
| Agent writes bad Terraform/IaC | OpenBao gives scoped creds but can't review IaC quality | Use OPA/Sentinel policies, terraform plan review |
| Agent exfiltrates secrets it fetched | Once a secret is read into memory, OpenBao has no control | Sandbox agent execution, network egress controls |
| Agent creates resources that cost money | IAM policies limit actions but not spend | AWS Budgets + billing alerts |
| Agent bypasses OpenBao entirely | If creds exist elsewhere (env, config), agent uses those | Remove all static creds, make OpenBao the only source |
| Compromised host running the agent | If the machine is owned, the attacker gets what the agent gets | Host hardening, minimal attack surface, monitoring |

### STS Credential Revocation Gap

AWS STS credentials, once issued, cannot be revoked by OpenBao. They remain valid until their TTL expires. This means:

- If you suspect a credential leak, you cannot invalidate in-flight STS tokens
- The blast radius window equals the STS TTL (1h default, up to 4h max)
- OpenBao's `bao lease revoke` revokes the OpenBao lease but does NOT invalidate the AWS credential

**Recovery procedure for suspected STS credential leak:**

1. Generate new IAM access keys for the OpenBao AWS engine root user
2. Update OpenBao: `bao write aws/config/root access_key=... secret_key=...`
3. Revoke the old IAM user's access keys in AWS console
4. All in-flight STS tokens remain valid until their TTL expires — monitor CloudTrail for suspicious activity during this window

**Mitigation:** Use shorter STS TTLs for production roles (15-30 min). The shorter the TTL, the smaller the blast radius.

The key insight: OpenBao defines the **ceiling** of what an agent can do. It does not define the **floor** of quality. You still need IaC review, policy-as-code, and monitoring to catch the agent doing things that are technically permitted but operationally dumb.

---

## Multi-Consumer Secret Access

Agents are one consumer of OpenBao. The same OpenBao instance also serves GitHub Actions, EKS pods, ECS tasks, and your local terminal. Each consumer authenticates differently but reads from the same KV hierarchy. You store a secret once; every consumer that needs it can fetch it through its own auth method.

### Consumer: GitHub Actions

GitHub Actions workflows authenticate to OpenBao via AppRole using the `openbao/vault-action` GitHub Action. You store exactly two secrets per environment in GitHub (the AppRole `role_id` and `secret_id`). Every other secret lives in OpenBao.

**GitHub repo settings (one-time):**

```
BAO_ADDR            = http://openbao:8200 (or Tailscale-accessible endpoint)
BAO_ROLE_ID_STAGING = <from onboard-project.sh output>
BAO_SECRET_ID_STAGING = <generated: bao write -f auth/approle/role/gha-<project>-staging/secret-id>
BAO_ROLE_ID_PROD    = <from onboard-project.sh output>
BAO_SECRET_ID_PROD  = <generated: bao write -f auth/approle/role/gha-<project>-prod/secret-id>
```

**Staging deploy workflow:**

```yaml
# .github/workflows/deploy-staging.yml
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Import secrets from OpenBao
        uses: openbao/vault-action@v3
        with:
          url: ${{ secrets.BAO_ADDR }}
          method: approle
          roleId: ${{ secrets.BAO_ROLE_ID_STAGING }}
          secretId: ${{ secrets.BAO_SECRET_ID_STAGING }}
          secrets: |
            secret/data/projects/clientA-platform/staging/database-url value | DATABASE_URL ;
            secret/data/projects/clientA-platform/staging/redis-url value | REDIS_URL ;
            secret/data/projects/clientA-platform/staging/openai-api-key value | OPENAI_API_KEY ;
            secret/data/shared/dockerhub-creds value | DOCKER_PASSWORD ;
            aws/creds/clientA-staging-deploy access_key | AWS_ACCESS_KEY_ID ;
            aws/creds/clientA-staging-deploy secret_key | AWS_SECRET_ACCESS_KEY ;
            aws/creds/clientA-staging-deploy security_token | AWS_SESSION_TOKEN

      - name: Deploy to staging
        run: |
          # All secrets are now in env vars — injected by openbao vault-action
          terraform init && terraform apply -auto-approve
```

**Prod deploy workflow — separate AppRole, separate policy:**

```yaml
# .github/workflows/deploy-prod.yml
jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: production    # GitHub environment protection rules apply
    steps:
      - uses: actions/checkout@v4

      - name: Import secrets from OpenBao
        uses: openbao/vault-action@v3
        with:
          url: ${{ secrets.BAO_ADDR }}
          method: approle
          roleId: ${{ secrets.BAO_ROLE_ID_PROD }}
          secretId: ${{ secrets.BAO_SECRET_ID_PROD }}
          secrets: |
            secret/data/projects/clientA-platform/prod/database-url value | DATABASE_URL ;
            secret/data/projects/clientA-platform/prod/redis-url value | REDIS_URL ;
            aws/creds/clientA-prod-deploy access_key | AWS_ACCESS_KEY_ID ;
            aws/creds/clientA-prod-deploy secret_key | AWS_SECRET_ACCESS_KEY ;
            aws/creds/clientA-prod-deploy security_token | AWS_SESSION_TOKEN
```

The staging AppRole physically cannot read prod secrets. Different AppRole, different policy, complete environment isolation.

**Networking consideration:** GitHub-hosted runners are outside your Tailscale network. Two options: expose OpenBao on a public HTTPS endpoint with strict mTLS/IP-allowlisting for GitHub's runner IP ranges, or use self-hosted runners on your homelab/AWS that are on the tailnet. Self-hosted runners with Kubernetes auth (if running in EKS) are the cleanest approach for the long term.

### Consumer: EKS Pods

EKS pods authenticate using their Kubernetes service account. No secrets to inject at deploy time — the pod's identity is the credential.

**Three methods to deliver secrets to pods, pick one per project:**

**Method A: OpenBao Agent Injector (recommended)**

The OpenBao Agent Injector runs as a mutating webhook in EKS. Annotate the deployment; the injector automatically adds an openbao-agent sidecar that fetches secrets and writes them to files the app container reads.

```yaml
# deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: clientA-app
  namespace: clientA-staging
spec:
  template:
    metadata:
      annotations:
        openbao.org/agent-inject: "true"
        openbao.org/role: "clientA-platform-staging"
        openbao.org/agent-inject-secret-db: "secret/data/projects/clientA-platform/staging/database-url"
        openbao.org/agent-inject-template-db: |
          {{- with secret "secret/data/projects/clientA-platform/staging/database-url" -}}
          {{ .Data.data.value }}
          {{- end }}
        openbao.org/agent-inject-secret-redis: "secret/data/projects/clientA-platform/staging/redis-url"
        openbao.org/agent-inject-template-redis: |
          {{- with secret "secret/data/projects/clientA-platform/staging/redis-url" -}}
          {{ .Data.data.value }}
          {{- end }}
    spec:
      serviceAccountName: clientA-app
      containers:
        - name: app
          image: clientA-app:latest
          env:
            - name: DATABASE_URL
              value: "file:///vault/secrets/db"     # App reads from file
            - name: REDIS_URL
              value: "file:///vault/secrets/redis"
```

The sidecar authenticates to OpenBao using the pod's ServiceAccount, fetches the declared secrets, and writes them to `/vault/secrets/`. When secrets rotate in OpenBao, the sidecar re-fetches and updates the files.

**Method B: External Secrets Operator (ESO)**

ESO syncs OpenBao secrets to native Kubernetes Secrets. The app uses K8s Secrets as usual — no code changes, no file reading. ESO periodically polls OpenBao and updates the K8s Secret.

```yaml
# external-secret.yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: clientA-app-secrets
  namespace: clientA-staging
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: openbao-backend
    kind: ClusterSecretStore
  target:
    name: clientA-app-secrets    # K8s Secret name
  data:
    - secretKey: DATABASE_URL
      remoteRef:
        key: projects/clientA-platform/staging/database-url
        property: value
    - secretKey: REDIS_URL
      remoteRef:
        key: projects/clientA-platform/staging/redis-url
        property: value
---
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: openbao-backend
spec:
  provider:
    vault:                            # ESO provider type remains "vault" for OpenBao compatibility
      server: "http://openbao:8200"
      path: "secret"
      version: "v2"
      auth:
        kubernetes:
          mountPath: "kubernetes-eks"
          role: "eso-reader"
          serviceAccountRef:
            name: external-secrets-sa
```

ESO is the lowest-friction option if your apps already consume K8s Secrets via `envFrom` or volume mounts. The tradeoff: there's a sync delay (up to `refreshInterval`) between an OpenBao secret rotation and the K8s Secret updating.

**Method C: OpenBao CSI Provider**

Mounts secrets as a volume using the Secrets Store CSI driver. Similar to Method A but uses the CSI driver instead of the injector webhook. Better for environments where mutating webhooks are restricted.

**Recommendation:** Start with ESO if your apps already use K8s Secrets. Use the Agent Injector if you want tighter OpenBao integration and real-time secret refresh.

### Consumer: ECS Tasks

ECS tasks authenticate to OpenBao using AWS IAM auth. The task's execution role is the credential.

**Container entrypoint pattern:**

```bash
#!/bin/bash
# entrypoint-openbao.sh — runs before the app starts

set -euo pipefail

# Authenticate to OpenBao using the task's IAM role
# The AWS SDK on the container provides the IAM identity automatically
export BAO_ADDR="http://openbao:8200"
BAO_TOKEN=$(bao login -method=aws role=clientA-staging-ecs -field=token)
export BAO_TOKEN

# Fetch secrets
export DATABASE_URL=$(bao kv get -field=value -mount=secret projects/clientA-platform/staging/database-url)
export REDIS_URL=$(bao kv get -field=value -mount=secret projects/clientA-platform/staging/redis-url)
export STRIPE_KEY=$(bao kv get -field=value -mount=secret projects/clientA-platform/staging/stripe-key)

# Unset OpenBao token — app doesn't need it
unset BAO_TOKEN

# Start the app
exec "$@"
```

**ECS task definition:**

```json
{
  "containerDefinitions": [
    {
      "name": "clientA-app",
      "image": "clientA-app:latest",
      "entryPoint": ["/entrypoint-openbao.sh"],
      "command": ["node", "server.js"]
    }
  ],
  "taskRoleArn": "arn:aws:iam::<account-id>:role/clientA-staging-task-role"
}
```

The task role must match what was configured in OpenBao's AWS auth method (`bound_iam_principal_arn`). The container fetches secrets at startup, then the app runs with secrets in its environment.

**Alternative for ECS:** Use OpenBao Agent (`bao agent`) as a sidecar container in the task definition. The sidecar handles auth and writes secrets to a shared volume that the app container reads. More complex task definition but decouples the app from the `bao` CLI dependency.

### Consumer: Your Terminal (Local Dev)

**Quick fetch:**

```bash
# Source secrets for a project into your shell
export DATABASE_URL=$(bao kv get -field=value -mount=secret projects/clientA-platform/staging/database-url)
export REDIS_URL=$(bao kv get -field=value -mount=secret projects/clientA-platform/staging/redis-url)
```

**Session launcher (reads .openbao-manifest.yaml):**

The session launcher from the Harness Mode section reads the manifest from your project repo, authenticates with the project-scoped AppRole, and injects exactly the declared secrets into your environment. See the Harness Mode section below for the full flow.

**bao agent with template rendering:**

`bao agent` runs as a background service on your dev machine, renders secrets to a `.env` file from a template, and re-renders when secrets rotate:

```
# Template: ~/.openbao/templates/clientA-staging.tpl
{{ with secret "secret/data/projects/clientA-platform/staging/database-url" }}
DATABASE_URL={{ .Data.data.value }}
{{ end }}
{{ with secret "secret/data/projects/clientA-platform/staging/redis-url" }}
REDIS_URL={{ .Data.data.value }}
{{ end }}
```

Your app sources the rendered file: `source ~/.openbao/rendered/clientA-staging.env && npm start`

### How Secret Rotation Works Across Consumers

When you rotate a secret in OpenBao, each consumer picks it up differently:

| Consumer | How it gets the new value | Delay |
|---|---|---|
| Your terminal | Next `bao kv get` call or `bao agent` re-renders template | Immediate on next fetch |
| Claude Code / agents | Next session start, or `bao agent` re-renders mid-session | Immediate on next fetch |
| GitHub Actions | Next workflow run fetches from OpenBao | Next CI run |
| EKS (Agent Injector) | Sidecar detects secret change, re-writes file | ~30s (configurable) |
| EKS (ESO) | ESO polls OpenBao, updates K8s Secret | Up to `refreshInterval` |
| ECS | Next task start fetches new value | Next deployment/task restart |

One `bao kv put` command. Zero downstream config changes. Every consumer gets the new value on its next access cycle.

---

## Harness Mode: Mediated Secret Access

Simple Mode (wrapper scripts, env var injection) works for solo dev. Harness Mode is the production-grade pattern where the harness — your session launcher, orchestration tool, or CI pipeline — owns the OpenBao relationship and mediates all agent access to secrets.

The fundamental shift: in Simple Mode, secrets are **pushed** into the agent's environment at startup. In Harness Mode, secrets are **pulled** by the agent through a mediated interface when it actually needs them.

### Why Harness Mode Exists

Five problems with Simple Mode that compound in real agentic workflows:

**Pre-fetch blast radius.** The wrapper fetches all secrets at session start. Agent working on CSS has AWS deploy creds in its env. Every subprocess (`terraform`, `curl`, `npm`) inherits everything. A rogue subprocess exfiltrates the lot.

**Token expiry during long tasks.** 1-hour TTL is safe but breaks during a long `terraform apply` or multi-step deployment. The agent is mid-mutation with expired creds and no way to re-authenticate without restarting the session.

**No context switching.** Moving from client-A work to client-B requires killing the session and re-launching with different AppRole creds. No hot-switch, no session isolation within a single dev session.

**No audit correlation.** OpenBao audit logs show "claude-code-agent read secret/data/agents/deploy at 14:32." They don't show "this was during the 'deploy landing page' task for client-A in session abc123." Without correlation, audit logs are noise.

**Sub-agent credential leakage.** Claude Code shells out to child processes that inherit the full environment. The agent can't selectively share credentials with specific subprocesses.

### bao agent: The Token Lifecycle Manager

Instead of bash wrappers managing token renewal, `bao agent` runs as a persistent background daemon on any machine hosting agents. It handles auto-auth, token renewal, secret caching, and local API proxying.

**How it fits:**

```
┌─────────────────────────────────────────────┐
│  Agent Host (dev machine / K8s pod / CI)    │
│                                             │
│  ┌─────────────┐    ┌──────────────────┐   │
│  │ Agent       │───▶│ bao agent        │   │
│  │ (Claude Code│    │ localhost:8100   │   │
│  │  n8n, etc.) │    │                  │   │
│  └─────────────┘    │ - auto-auth      │   │
│                     │ - token renewal   │   │
│                     │ - secret caching  │   │
│                     │ - template render │   │
│                     └────────┬─────────┘   │
└──────────────────────────────┼─────────────┘
                               │ (Tailscale)
                        ┌──────▼──────┐
                        │ OpenBao(EC2)│
                        └─────────────┘
```

The agent (or its MCP server) talks to `localhost:8100` instead of directly to OpenBao. `bao agent` handles authentication, caching, and renewal transparently. If the token is about to expire during a long task, `bao agent` renews it before the agent notices.

For Kubernetes workloads (n8n, CrewAI on the homelab cluster), the OpenBao Agent Injector automatically deploys `bao agent` as a sidecar container. No manual setup per pod — just annotate the deployment and the injector handles the rest.

### Session-Scoped Identity

Every agent session should carry metadata that ties OpenBao audit entries back to the specific task, client, and context.

**The harness creates tokens with metadata:**

```bash
SESSION_ID=$(uuidgen)
AGENT_TOKEN=$(bao token create \
  -policy=agent-aws-clientA-staging \
  -ttl=4h \
  -display-name="claude-code/clientA/deploy-landing-page" \
  -metadata="session_id=${SESSION_ID}" \
  -metadata="client=clientA" \
  -metadata="environment=staging" \
  -metadata="task=deploy-landing-page" \
  -metadata="repo=clientA-infra" \
  -field=token)
```

Every OpenBao audit log entry for this token now includes all that metadata. Debugging "who read the database password at 3am" traces to the exact session, client, and task.

**OpenBao entity aggregation:**

For agents that authenticate repeatedly across sessions, OpenBao entities aggregate activity under a persistent identity:

```bash
bao write identity/entity \
  name="claude-code-agent" \
  metadata=agent_type="claude-code" \
  metadata=owner="chinmay"
```

Now you can query all activity by `claude-code-agent` across all sessions, regardless of which token was active.

### Multi-Client Credential Isolation

Agency work means switching between client projects. The harness enforces isolation by selecting the right AppRole per client-environment pair.

**One AppRole per client-environment:**

```
auth/approle/role/agent-clientA-staging   → policy: clientA-staging-aws, clientA-staging-kv
auth/approle/role/agent-clientA-prod      → policy: clientA-prod-aws, clientA-prod-kv
auth/approle/role/agent-clientB-staging   → policy: clientB-staging-aws, clientB-staging-kv
```

**The harness reads context from the project:**

```bash
# Session launcher reads project config
CLIENT=$(git config --get project.client || echo "personal")
ENV=$(git config --get project.environment || echo "staging")
ROLE="agent-${CLIENT}-${ENV}"

# Authenticate with context-appropriate AppRole
AGENT_TOKEN=$(bao write -field=token auth/approle/login \
  role_id=$(bao read -field=role_id auth/approle/role/${ROLE}/role-id) \
  secret_id=$(bao write -f -field=secret_id auth/approle/role/${ROLE}/secret-id))
```

The agent physically cannot access client-B's secrets while working on client-A. The isolation is enforced by OpenBao policy, not by the developer remembering to switch contexts.

**KV path structure for multi-client:**

```
secret/
├── agents/
│   └── ...shared agent configs...
├── clients/
│   ├── clientA/
│   │   ├── staging/
│   │   │   ├── aws-account-id
│   │   │   ├── database-url
│   │   │   └── api-keys
│   │   └── prod/
│   │       └── ...
│   └── clientB/
│       └── ...
└── personal/
    └── ...homelab, side projects...
```

### Lease Tracking and Session Cleanup

The harness tracks every OpenBao lease created during a session and revokes them all on exit — normal or abnormal (ctrl-c, crash, kill).

**Why this matters:** Without cleanup, a killed agent leaves AWS STS credentials valid for up to their full TTL. With cleanup, credentials are revoked within seconds of session end.

```bash
# Trap-based cleanup in session launcher
LEASE_FILE="/tmp/openbao-leases-${SESSION_ID}"
touch "$LEASE_FILE"

cleanup() {
  while IFS= read -r lease_id; do
    bao lease revoke "$lease_id" 2>/dev/null || true
  done < "$LEASE_FILE"
  BAO_TOKEN="$AGENT_TOKEN" bao token revoke -self 2>/dev/null || true
  rm -f "$LEASE_FILE"
}
trap cleanup EXIT INT TERM

# When fetching dynamic creds, track the lease
AWS_RESPONSE=$(bao read -format=json aws/creds/agent-deploy)
echo "$AWS_RESPONSE" | jq -r '.lease_id' >> "$LEASE_FILE"
```

**Integration with tmux session launcher:** The teardown function in your tmux session script calls this cleanup before killing the pane. Every `ctrl-c` or `tmux kill-pane` triggers immediate credential revocation.

### Credential Request Gating

Some secret accesses should require human approval before the agent gets the credential.

**Risk classification at the harness level:**

```
Low risk  (auto-approve):  staging KV reads, personal secrets, dev AWS creds
High risk (human approval): production AWS creds, client prod secrets, IAM-related paths
```

The harness classifies each request based on the path pattern. Low-risk flows through instantly. High-risk sends a notification (Slack webhook, Telegram bot, push notification to your React Native remote control app) and blocks until you approve.

This is the practical version of OpenBao's Control Groups concept: the harness enforces the approval flow before the request ever reaches OpenBao.

### Sub-Agent Credential Containment

When Claude Code runs `terraform apply`, that subprocess inherits the full environment. Two patterns to limit this:

**Pattern A: AWS credential_process (recommended)**

Instead of env vars, configure the AWS SDK to fetch credentials on demand from `bao agent`:

```ini
# ~/.aws/config
[profile agent]
credential_process = /usr/local/bin/openbao-credential-helper.sh
```

The helper script calls `bao agent`'s local proxy, gets STS creds, and returns them in the credential_process JSON format. Credentials are never in environment variables. A rogue subprocess that runs `env` or `printenv` sees nothing.

**Important:** The helper script must have `0600` permissions (`chmod 0600 openbao-credential-helper.sh`) and `bao agent`'s token file at `~/.openbao/agent-token` must also be `0600`. Test this pattern with your specific tools (`terraform`, `aws-cli`, `boto3`) before relying on it — some SDKs fall back to environment variables if `credential_process` fails, which defeats the isolation purpose.

**Pattern B: Process-specific env injection**

For tools that can't use credential_process, use `env -i` to launch subprocesses with a minimal, explicitly-constructed environment:

```bash
env -i PATH="$PATH" HOME="$HOME" \
  GITHUB_TOKEN="$(bao kv get -field=value secret/agents/ci/github-token)" \
  terraform apply
```

Each subprocess gets only the credentials it needs. More verbose, but explicit.

---

## OpenBao MCP Server: Agent-Native Secret Access

The highest-leverage integration pattern. Instead of wrapper scripts or env vars, expose OpenBao as a set of MCP tools that any agent can call natively through the standard tool-use interface.

### Why MCP Changes the Model

With wrappers, the agent doesn't know where its credentials came from. They're just env vars. The agent can't reason about "I need AWS credentials for this specific task" or "I should check what secrets are available before proceeding."

With MCP, secret access becomes a first-class agent action:

```
Agent thinks: "I need to deploy to AWS. Let me check what credentials I have."
Agent calls:  list_available_secrets
Agent sees:   ["aws/creds/clientA-staging-deploy", "secret/agents/claude-code/github-token"]
Agent thinks: "I need staging AWS creds for this Terraform apply."
Agent calls:  get_aws_credentials(role="clientA-staging-deploy", ttl="1h")
Agent gets:   { access_key: "ASIA...", expiry: "2025-03-08T16:00:00Z" }
Agent thinks: "Now I can run terraform. Creds expire in 1h, so I need to finish before then."
```

The agent is a participant in the credential lifecycle, not a passive consumer of env vars.

### MCP Tool Interface

Four tools exposed by the OpenBao MCP server:

**`read_secret`** — Fetch a static secret from KV v2. Parameters: `path` (string). Returns the secret value. Only paths allowed by the current session policy are accessible.

**`get_aws_credentials`** — Generate ephemeral AWS STS credentials. Parameters: `role` (string), `ttl` (string, optional). Returns access key, secret key, session token, and expiry time. The MCP server tracks the lease for cleanup.

**`list_available_secrets`** — Enumerate what the agent can access in the current session context. No parameters. Returns a list of accessible KV paths and AWS roles. Helps the agent discover capabilities without guessing.

**`encrypt_data`** — Encrypt sensitive data via OpenBao Transit engine. Parameters: `plaintext` (string), `key_name` (string, optional). Returns ciphertext. Useful when agents need to store sensitive data in logs or databases without exposing plaintext.

### Session Policy Enforcement

The MCP server doesn't just proxy to OpenBao — it adds a session-level policy layer on top of OpenBao policies.

When the harness launches a session, it writes a session config:

```json
{
  "session_id": "abc-123",
  "client": "clientA",
  "environment": "staging",
  "allowed_kv_prefixes": ["agents/claude-code/", "clients/clientA/staging/"],
  "allowed_aws_roles": ["clientA-staging-deploy"],
  "denied_patterns": ["*/prod/*"],
  "risk_gate": {
    "high_risk_patterns": ["*/prod/*", "aws/creds/*-prod*"],
    "webhook": "https://hooks.slack.com/..."
  }
}
```

The MCP server reads this config at startup and enforces it on every tool call. Even if the OpenBao policy technically allows broader access (e.g., the AppRole has read on `clients/clientA/*`), the MCP server restricts to the session-specific subset. Double-layered enforcement: OpenBao policies define the ceiling, session config defines the working scope.

### Claude Code Integration

Register the OpenBao MCP server in Claude Code's MCP config:

```json
{
  "mcpServers": {
    "openbao": {
      "command": "node",
      "args": ["/path/to/openbao-mcp-server/dist/index.js"],
      "env": {
        "BAO_AGENT_ADDR": "http://localhost:8100",
        "SESSION_CONFIG": "/home/<user>/.openbao/current-session.json"
      }
    }
  }
}
```

Claude Code now has `read_secret`, `get_aws_credentials`, `list_available_secrets`, and `encrypt_data` as native tools in its tool palette. The session launcher writes `current-session.json` before launching Claude Code, configuring the OpenBao MCP server for the current client/environment context.

### MCP Server Lifecycle

```
Session launcher starts
    │
    ├─▶ Writes session config (client, env, allowed paths)
    ├─▶ Ensures bao agent is running (auto-auth, cache proxy)
    ├─▶ Launches Claude Code (which starts MCP server via mcp.json)
    │
    │   ┌─── Agent runs, calls MCP tools as needed ───┐
    │   │                                              │
    │   │  read_secret ──▶ MCP server ──▶ bao agent ──▶ OpenBao
    │   │  get_aws_creds ──▶ MCP server ──▶ bao agent ──▶ OpenBao
    │   │                                              │
    │   │  MCP server tracks leases in memory          │
    │   │  MCP server enforces session policy           │
    │   │  MCP server gates high-risk requests          │
    │   └──────────────────────────────────────────────┘
    │
Session ends (normal exit, ctrl-c, crash)
    │
    ├─▶ MCP server cleanup: revoke all tracked leases
    ├─▶ Harness cleanup: revoke session token
    └─▶ Session config deleted
```

### Implementation Priority

Build order:

1. **Phases 1-6:** Get OpenBao running on EC2, stable, backed up. Use Simple Mode wrappers to validate the setup works.
2. **Phase 7.2:** Deploy `bao agent` on your dev machine. Replace the bash wrapper's token management with `bao agent` auto-auth and caching.
3. **Phase 7.3-7.5:** Add session metadata, multi-client isolation, and lease cleanup to your session launcher.
4. **Phase 8:** Build the OpenBao MCP server. Start with `read_secret` and `get_aws_credentials`, add the other tools iteratively.
5. **Phase 7.6:** Add credential gating once the MCP server is working — the MCP server is the natural place to enforce approval flows.

The MCP server is also a strong open-source project for the agency. A generic OpenBao MCP server for agentic coding doesn't exist yet in the ecosystem. Building and open-sourcing it positions works-on-my.cloud at the intersection of agentic AI and infrastructure security — exactly where you want to be.

---

## Updated Agent Onboarding Checklist

When adding a new agent or agentic workflow to the system:

1. **Define the secret scope** — what secrets does this agent actually need? List them explicitly.
2. **Create the OpenBao policy** — write an HCL policy granting read access to exactly those paths. No wildcards unless unavoidable.
3. **Create the AppRole** — with appropriate TTLs and use limits. For multi-client: one AppRole per client-environment pair.
4. **If using AWS dynamic creds** — define the IAM policy document for the role. Start with minimal permissions, expand only when the agent fails on specific actions.
5. **Choose the integration mode:**
   - **Simple Mode:** Write a wrapper script for local dev / quick prototyping.
   - **Harness Mode:** Configure `bao agent` template, session metadata, lease tracking in your session launcher.
   - **MCP Mode:** Add allowed paths and roles to the MCP session config template.
6. **Configure session metadata** — define the token display-name and metadata fields for audit correlation.
7. **Define risk classification** — which secret paths are low-risk (auto-approve) vs high-risk (gated)?
8. **Test with a dry run** — run the agent, verify it can authenticate and read secrets. For MCP: verify tool calls return expected results.
9. **Enable audit log monitoring** — add a query in SigNoz that alerts if this agent makes unexpected access patterns. Correlate by session metadata.

10. **Document in the agent registry** — add the agent to the table below.

---

## Updated Agent Registry

| Agent | Mode | Auth Method | AppRole | Policy | Dynamic AWS | TTL | Risk Gate | Status |
|---|---|---|---|---|---|---|---|---|
| Claude Code (local dev) | Simple | AppRole | claude-code-agent | agent-aws, agent-kv-readonly | Yes (1h STS) | 1h | No | Active |
| Claude Code (client work) | MCP | AppRole | agent-{client}-{env} | per-client scoped | Yes (1h STS) | 4h | Prod: yes | Planned |
| n8n (homelab) | Harness | Kubernetes | n/a (SA-based) | agent-kv-readonly | No | 1h | No | Planned |
| GitHub Actions CI | Harness | AppRole | ci-deploy | ci-deploy | Yes (30m STS) | 30m | Prod: yes | Planned |
| Content Pipeline | Simple | AppRole | content-agent | agent-kv-readonly | No | 2h | No | Planned |
| CrewAI (homelab) | Harness | Kubernetes | n/a (SA-based) | per-pipeline scoped | Optional | 2h | No | Planned |

---

## Secret Rotation Schedule

| Secret Type | Rotation Frequency | Method | Owner |
|---|---|---|---|
| AWS dynamic creds | Auto (per-session TTL) | OpenBao AWS engine handles it | Automatic |
| AppRole secret_ids | Daily | Cron job or wrapper script generates new secret_id | Automated |
| KV static secrets (API keys) | 90 days | Manual update in OpenBao, notify dependent agents | You |
| OpenBao AWS engine root creds | 90 days | Rotate IAM user access key, update OpenBao config | You |
| Recovery keys | Never (unless compromised) | Re-init required to change | You |

---

## Failure Modes and What Happens

| Scenario | Impact | Agent Behaviour | Recovery |
|---|---|---|---|
| OpenBao is down | No new secret fetches | Simple Mode: agents with cached env vars work until creds expire. Harness/MCP Mode: `bao agent` serves from cache if available, otherwise fails. | Restore from snapshot or reboot instance. |
| Tailscale is down | Cannot reach OpenBao | Same as OpenBao down from agent perspective. `bao agent` cache may cover short outages. | Wait for Tailscale recovery or use emergency SSH. |
| KMS is unavailable | OpenBao cannot unseal on restart | If already running and unsealed, no impact. If restarted, stays sealed until KMS recovers. | Wait for AWS KMS recovery (extremely rare). |
| AWS creds expired mid-task | Terraform apply fails partway | Simple Mode: session must restart. Harness/MCP Mode: `bao agent` or MCP server can re-fetch transparently if configured. | Re-authenticate, re-run. `terraform plan` to assess drift. |
| AppRole secret_id expired | Agent cannot authenticate | `bao agent` handles re-auth automatically. Simple Mode wrappers need manual restart. | Generate new secret_id, restart agent (or let `bao agent` handle it). |
| `bao agent` crashes | Token renewal stops, cache unavailable | Agent loses mediated access. Falls back to last-known token until TTL expires. | Restart `bao agent` (systemd auto-restart handles this). |
| MCP server crashes | Agent loses tool access to secrets | Agent cannot call read_secret or get_aws_credentials. Existing env-injected creds (if any) still work. | Claude Code can be restarted, MCP server re-initialises with session config. |

The most important operational discipline: **never work around OpenBao when it's down.** Don't paste credentials into .env files "temporarily." Don't create long-lived IAM keys "just until OpenBao is back." Fix OpenBao first, then resume work. The moment you create an escape hatch, the escape hatch becomes the standard path.

---

## References

- OpenBao AppRole Auth Method: https://openbao.org/docs/auth/approle
- OpenBao Kubernetes Auth Method: https://openbao.org/docs/auth/kubernetes
- OpenBao AWS IAM Auth Method: https://openbao.org/docs/auth/aws
- OpenBao AWS Secrets Engine: https://openbao.org/docs/secrets/aws
- OpenBao KV v2 Secrets Engine: https://openbao.org/docs/secrets/kv/kv-v2
- OpenBao Transit Secrets Engine: https://openbao.org/docs/secrets/transit
- OpenBao Policies: https://openbao.org/docs/concepts/policies
- OpenBao Tokens and Metadata: https://openbao.org/docs/concepts/tokens
- OpenBao Identity and Entities: https://openbao.org/docs/concepts/identity
- OpenBao Agent Auto-Auth: https://openbao.org/docs/agent-and-proxy/agent/auto-auth
- OpenBao Agent Caching and Proxying: https://openbao.org/docs/agent-and-proxy/agent/caching
- OpenBao Agent Template Rendering: https://openbao.org/docs/agent-and-proxy/agent/template
- OpenBao Agent Injector for Kubernetes: https://openbao.org/docs/platform/k8s/injector
- OpenBao CSI Provider: https://openbao.org/docs/platform/k8s/csi
- OpenBao Audit Devices: https://openbao.org/docs/audit
- OpenBao Lease Management: https://openbao.org/docs/concepts/lease
- External Secrets Operator — OpenBao Provider: https://external-secrets.io/latest/provider/hashicorp-vault/
- GitHub Actions vault-action (OpenBao fork): https://github.com/openbao/vault-action
- AWS credential_process for External Credential Sourcing: https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sourcing-external.html
- MCP Specification: https://modelcontextprotocol.io/specification
- MCP TypeScript SDK: https://github.com/modelcontextprotocol/typescript-sdk
- Claude Code MCP Configuration: https://docs.claude.com/en/docs/claude-code/mcp
