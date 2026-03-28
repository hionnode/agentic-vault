#!/bin/bash
# validate-init.sh — Post-init validation checks
# Run after init-openbao.sh + teardown-root.sh to verify the deployment.
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
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
  echo "WARNING: Some checks failed. Review before proceeding."
  exit 1
fi
