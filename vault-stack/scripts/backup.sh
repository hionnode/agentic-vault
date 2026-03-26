#!/bin/bash
# backup.sh — Raft snapshot to S3
# Called by cron via /usr/local/bin/vault-backup.sh wrapper (sets env vars).
# Environment: VAULT_ADDR, BACKUP_BUCKET, BACKUP_KMS_KEY, AWS_DEFAULT_REGION
set -euo pipefail

VAULT_ADDR="${VAULT_ADDR:-http://$(tailscale ip -4):8200}"
export VAULT_ADDR

SNAPSHOT_DIR="/tmp/vault-snapshots"
TIMESTAMP=$(date -u +"%Y%m%d-%H%M%S")
SNAPSHOT_FILE="$SNAPSHOT_DIR/vault-raft-$TIMESTAMP.snap"
S3_KEY="snapshots/vault-raft-$TIMESTAMP.snap"

mkdir -p "$SNAPSHOT_DIR"

echo "[$(date -u)] Starting Vault Raft snapshot"

# Check Vault health before snapshot
if ! curl -sf "$VAULT_ADDR/v1/sys/health" > /dev/null 2>&1; then
  echo "[$(date -u)] ERROR: Vault is not healthy, skipping snapshot"
  exit 1
fi

# Take Raft snapshot
if ! vault operator raft snapshot save "$SNAPSHOT_FILE"; then
  echo "[$(date -u)] ERROR: Failed to save Raft snapshot"
  rm -f "$SNAPSHOT_FILE"
  exit 1
fi

SNAP_SIZE=$(stat -c%s "$SNAPSHOT_FILE" 2>/dev/null || stat -f%z "$SNAPSHOT_FILE")
echo "[$(date -u)] Snapshot saved: $SNAPSHOT_FILE ($SNAP_SIZE bytes)"

# Upload to S3 with KMS encryption
if ! aws s3 cp "$SNAPSHOT_FILE" "s3://$BACKUP_BUCKET/$S3_KEY" \
  --sse aws:kms \
  --sse-kms-key-id "$BACKUP_KMS_KEY" \
  --region "$AWS_DEFAULT_REGION"; then
  echo "[$(date -u)] ERROR: Failed to upload snapshot to S3"
  rm -f "$SNAPSHOT_FILE"
  exit 1
fi

echo "[$(date -u)] Snapshot uploaded to s3://$BACKUP_BUCKET/$S3_KEY"

# Cleanup local snapshot
rm -f "$SNAPSHOT_FILE"

# Cleanup old local snapshots (keep none — S3 is the source of truth)
find "$SNAPSHOT_DIR" -name "vault-raft-*.snap" -mmin +60 -delete 2>/dev/null || true

echo "[$(date -u)] Backup completed successfully"
