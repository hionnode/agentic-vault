#!/bin/bash
# user-data.sh — Cloud-init script for OpenBao EC2 instance
# Passed via templatefile() in main.tf. Template variables:
#   ${openbao_version}, ${kms_key_id}, ${aws_region},
#   ${tailscale_authkey}, ${backup_bucket}, ${backup_kms_key}
set -euo pipefail

# --- Structured logging ---
exec > >(tee /var/log/user-data.log | logger -t user-data) 2>&1
echo "=== OpenBao user-data starting at $(date -u) ==="

# --- System updates ---
echo "--- Step 1: System updates ---"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y
apt-get install -y unattended-upgrades jq curl gnupg

# Enable unattended security upgrades
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'APTCONF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APTCONF

# --- Install OpenBao (pinned .deb package with checksum verification) ---
echo "--- Step 2: Install OpenBao ${openbao_version} ---"
BAO_VERSION="${openbao_version}"
BAO_DEB="bao_$${BAO_VERSION}_linux_arm64.deb"
BAO_URL="https://github.com/openbao/openbao/releases/download/v$${BAO_VERSION}/$${BAO_DEB}"
BAO_CHECKSUMS_URL="https://github.com/openbao/openbao/releases/download/v$${BAO_VERSION}/bao_$${BAO_VERSION}_SHA256SUMS"

cd /tmp
curl -fsSL "$${BAO_URL}" -o "$${BAO_DEB}"
curl -fsSL "$${BAO_CHECKSUMS_URL}" -o SHA256SUMS

# Verify checksum
grep "$${BAO_DEB}" SHA256SUMS | sha256sum --check -
dpkg -i "$${BAO_DEB}"
rm -f "$${BAO_DEB}" SHA256SUMS

bao --version
echo "OpenBao binary installed successfully"

# --- Create openbao user and directories ---
echo "--- Step 3: Create openbao user and directories ---"
useradd --system --home /etc/openbao --shell /bin/false openbao || true
mkdir -p /opt/openbao/data /var/log/openbao /etc/openbao
chown -R openbao:openbao /opt/openbao /var/log/openbao /etc/openbao
chmod 750 /opt/openbao/data

# --- Write systemd unit ---
echo "--- Step 4: Write systemd unit ---"
cat > /etc/systemd/system/openbao.service <<'SYSTEMD'
[Unit]
Description="OpenBao - A tool for managing secrets"
Documentation=https://openbao.org/docs
Requires=network-online.target
After=network-online.target
ConditionFileNotEmpty=/etc/openbao/openbao.hcl

[Service]
User=openbao
Group=openbao
ExecStart=/usr/local/bin/bao server -config=/etc/openbao/openbao.hcl
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
  --hostname=openbao \
  --advertise-tags=tag:infra \
  --timeout=60s

TAILSCALE_IP=$(tailscale ip -4)
echo "Tailscale IP: $${TAILSCALE_IP}"

if [ -z "$${TAILSCALE_IP}" ]; then
  echo "FATAL: Failed to get Tailscale IP. Aborting."
  exit 1
fi

# --- Write openbao.hcl ---
echo "--- Step 7: Write openbao.hcl ---"
cat > /etc/openbao/openbao.hcl <<BAOHCL
ui = true

listener "tcp" {
  address     = "$${TAILSCALE_IP}:8200"
  tls_disable = true  # Tailscale WireGuard handles encryption
}

storage "raft" {
  path    = "/opt/openbao/data"
  node_id = "openbao-1"
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
BAOHCL

chown openbao:openbao /etc/openbao/openbao.hcl
chmod 640 /etc/openbao/openbao.hcl

# --- Start OpenBao ---
echo "--- Step 8: Start OpenBao ---"
systemctl daemon-reload
systemctl enable openbao
systemctl start openbao

# Health check polling
echo "--- Step 9: Health check ---"
for i in $(seq 1 30); do
  if curl -sf "http://$${TAILSCALE_IP}:8200/v1/sys/health?standbyok=true&uninitcode=200&sealedcode=200" > /dev/null 2>&1; then
    echo "OpenBao is responding (attempt $${i})"
    break
  fi
  echo "Waiting for OpenBao to start (attempt $${i}/30)..."
  sleep 2
done

# Verify OpenBao is actually responding
if ! curl -sf "http://$${TAILSCALE_IP}:8200/v1/sys/health?standbyok=true&uninitcode=200&sealedcode=200" > /dev/null 2>&1; then
  echo "FATAL: OpenBao failed to start after 60 seconds"
  journalctl -u openbao --no-pager -n 50
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

# --- Logrotate for OpenBao audit ---
echo "--- Step 11: Configure logrotate ---"
cat > /etc/logrotate.d/openbao <<'LOGROTATE'
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
LOGROTATE

# --- Setup backup cron ---
echo "--- Step 12: Setup backup cron ---"
cat > /usr/local/bin/openbao-backup.sh <<'BACKUP'
#!/bin/bash
# Wrapper that sets environment for the backup script
export BAO_ADDR="http://$(tailscale ip -4):8200"
export BACKUP_BUCKET="${backup_bucket}"
export BACKUP_KMS_KEY="${backup_kms_key}"
export AWS_DEFAULT_REGION="${aws_region}"
/opt/openbao/scripts/backup.sh
BACKUP
chmod 755 /usr/local/bin/openbao-backup.sh

mkdir -p /opt/openbao/scripts
# backup.sh will be deployed separately (see scripts/backup.sh)

echo "0 */6 * * * root /usr/local/bin/openbao-backup.sh >> /var/log/openbao/backup.log 2>&1" > /etc/cron.d/openbao-backup
chmod 644 /etc/cron.d/openbao-backup

echo "=== OpenBao user-data completed at $(date -u) ==="
echo "Next step: SSM into instance and run init-openbao.sh"
