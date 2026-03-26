#!/bin/bash
# user-data.sh — Cloud-init script for Vault EC2 instance
# Passed via templatefile() in main.tf. Template variables:
#   ${vault_version}, ${kms_key_id}, ${aws_region},
#   ${tailscale_authkey}, ${backup_bucket}, ${backup_kms_key}
set -euo pipefail

# --- Structured logging ---
exec > >(tee /var/log/user-data.log | logger -t user-data) 2>&1
echo "=== Vault user-data starting at $(date -u) ==="

# --- System updates ---
echo "--- Step 1: System updates ---"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y
apt-get install -y unattended-upgrades jq unzip curl gnupg

# Enable unattended security upgrades
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'APTCONF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APTCONF

# --- Install Vault (pinned binary with checksum verification) ---
echo "--- Step 2: Install Vault ${vault_version} ---"
VAULT_VERSION="${vault_version}"
VAULT_ARCH="linux_arm64"
VAULT_URL="https://releases.hashicorp.com/vault/$${VAULT_VERSION}"
VAULT_ZIP="vault_$${VAULT_VERSION}_$${VAULT_ARCH}.zip"

cd /tmp
curl -fsSL "$${VAULT_URL}/$${VAULT_ZIP}" -o "$${VAULT_ZIP}"
curl -fsSL "$${VAULT_URL}/vault_$${VAULT_VERSION}_SHA256SUMS" -o SHA256SUMS
curl -fsSL "$${VAULT_URL}/vault_$${VAULT_VERSION}_SHA256SUMS.sig" -o SHA256SUMS.sig

# Verify checksum (GPG verification requires importing HashiCorp's key — see docs)
grep "$${VAULT_ZIP}" SHA256SUMS | sha256sum --check -
unzip -o "$${VAULT_ZIP}" -d /usr/local/bin
chmod 755 /usr/local/bin/vault
rm -f "$${VAULT_ZIP}" SHA256SUMS SHA256SUMS.sig

vault --version
echo "Vault binary installed successfully"

# --- Create vault user and directories ---
echo "--- Step 3: Create vault user and directories ---"
useradd --system --home /etc/vault.d --shell /bin/false vault || true
mkdir -p /opt/vault/data /var/log/vault /etc/vault.d
chown -R vault:vault /opt/vault /var/log/vault /etc/vault.d
chmod 750 /opt/vault/data

# --- Write systemd unit ---
echo "--- Step 4: Write systemd unit ---"
cat > /etc/systemd/system/vault.service <<'SYSTEMD'
[Unit]
Description="HashiCorp Vault - A tool for managing secrets"
Documentation=https://developer.hashicorp.com/vault/docs
Requires=network-online.target
After=network-online.target
ConditionFileNotEmpty=/etc/vault.d/vault.hcl

[Service]
User=vault
Group=vault
ExecStart=/usr/local/bin/vault server -config=/etc/vault.d/vault.hcl
ExecReload=/bin/kill --signal HUP $MAINPID
KillMode=process
KillSignal=SIGINT
Restart=on-failure
RestartSec=5
TimeoutStopSec=30
LimitNOFILE=65536
LimitMEMLOCK=infinity

# Hardening
ProtectSystem=full
ProtectHome=true
PrivateTmp=true
NoNewPrivileges=true
CapabilityBoundingSet=CAP_IPC_LOCK CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_IPC_LOCK

[Install]
WantedBy=multi-user.target
SYSTEMD

# --- Install Tailscale ---
echo "--- Step 5: Install Tailscale ---"
curl -fsSL https://tailscale.com/install.sh | sh

echo "--- Step 6: Bring Tailscale up ---"
tailscale up \
  --authkey="${tailscale_authkey}" \
  --hostname=vault \
  --advertise-tags=tag:infra \
  --timeout=60s

TAILSCALE_IP=$(tailscale ip -4)
echo "Tailscale IP: $${TAILSCALE_IP}"

if [ -z "$${TAILSCALE_IP}" ]; then
  echo "FATAL: Failed to get Tailscale IP. Aborting."
  exit 1
fi

# --- Write vault.hcl ---
echo "--- Step 7: Write vault.hcl ---"
cat > /etc/vault.d/vault.hcl <<VAULTHCL
ui = true

listener "tcp" {
  address     = "$${TAILSCALE_IP}:8200"
  tls_disable = true  # Tailscale WireGuard handles encryption
}

storage "raft" {
  path    = "/opt/vault/data"
  node_id = "vault-1"
}

seal "awskms" {
  region     = "${aws_region}"
  kms_key_id = "${kms_key_id}"
}

api_addr     = "http://$${TAILSCALE_IP}:8200"
cluster_addr = "http://$${TAILSCALE_IP}:8201"

telemetry {
  disable_hostname          = true
  prometheus_retention_time = "12h"
}
VAULTHCL

chown vault:vault /etc/vault.d/vault.hcl
chmod 640 /etc/vault.d/vault.hcl

# --- Start Vault ---
echo "--- Step 8: Start Vault ---"
systemctl daemon-reload
systemctl enable vault
systemctl start vault

# Health check polling
echo "--- Step 9: Health check ---"
for i in $(seq 1 30); do
  if curl -sf "http://$${TAILSCALE_IP}:8200/v1/sys/health?standbyok=true&uninitcode=200&sealedcode=200" > /dev/null 2>&1; then
    echo "Vault is responding (attempt $${i})"
    break
  fi
  echo "Waiting for Vault to start (attempt $${i}/30)..."
  sleep 2
done

# Verify Vault is actually responding
if ! curl -sf "http://$${TAILSCALE_IP}:8200/v1/sys/health?standbyok=true&uninitcode=200&sealedcode=200" > /dev/null 2>&1; then
  echo "FATAL: Vault failed to start after 60 seconds"
  journalctl -u vault --no-pager -n 50
  exit 1
fi

# --- Install CloudWatch Agent ---
echo "--- Step 10: Install CloudWatch Agent ---"
curl -fsSL "https://amazoncloudwatch-agent-${aws_region}.s3.${aws_region}.amazonaws.com/ubuntu/arm64/latest/amazon-cloudwatch-agent.deb" \
  -o /tmp/amazon-cloudwatch-agent.deb
dpkg -i /tmp/amazon-cloudwatch-agent.deb
rm -f /tmp/amazon-cloudwatch-agent.deb

# CloudWatch agent config
mkdir -p /opt/aws/amazon-cloudwatch-agent/etc
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json <<'CWCONFIG'
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
            "file_path": "/var/log/vault/audit.log",
            "log_group_name": "/vault/audit",
            "log_stream_name": "{instance_id}",
            "retention_in_days": 90,
            "timezone": "UTC"
          },
          {
            "file_path": "/var/log/syslog",
            "log_group_name": "/vault/system",
            "log_stream_name": "{instance_id}",
            "retention_in_days": 30,
            "timezone": "UTC"
          }
        ]
      }
    }
  },
  "metrics": {
    "namespace": "Vault",
    "metrics_collected": {
      "disk": {
        "measurement": ["used_percent"],
        "resources": ["/"],
        "metrics_collection_interval": 300
      },
      "mem": {
        "measurement": ["used_percent"],
        "metrics_collection_interval": 300
      }
    },
    "append_dimensions": {
      "InstanceId": "${aws:InstanceId}"
    }
  }
}
CWCONFIG

/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config -m ec2 \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json -s

# --- Logrotate for Vault audit ---
echo "--- Step 11: Configure logrotate ---"
cat > /etc/logrotate.d/vault <<'LOGROTATE'
/var/log/vault/audit.log {
    daily
    rotate 30
    compress
    missingok
    notifempty
    copytruncate
    postrotate
        systemctl reload vault >/dev/null 2>&1 || true
    endscript
}
LOGROTATE

# --- Setup backup cron ---
echo "--- Step 12: Setup backup cron ---"
cat > /usr/local/bin/vault-backup.sh <<'BACKUP'
#!/bin/bash
# Wrapper that sets environment for the backup script
export VAULT_ADDR="http://$(tailscale ip -4):8200"
export BACKUP_BUCKET="${backup_bucket}"
export BACKUP_KMS_KEY="${backup_kms_key}"
export AWS_DEFAULT_REGION="${aws_region}"
/opt/vault/scripts/backup.sh
BACKUP
chmod 755 /usr/local/bin/vault-backup.sh

mkdir -p /opt/vault/scripts
# backup.sh will be deployed separately (see scripts/backup.sh)

echo "0 */6 * * * root /usr/local/bin/vault-backup.sh >> /var/log/vault/backup.log 2>&1" > /etc/cron.d/vault-backup
chmod 644 /etc/cron.d/vault-backup

echo "=== Vault user-data completed at $(date -u) ==="
echo "Next step: SSM into instance and run init-vault.sh"
