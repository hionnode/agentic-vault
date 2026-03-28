#!/bin/bash
# init-openbao.sh — One-time OpenBao initialization
# Run manually via SSM after first boot. Do NOT run more than once.
set -euo pipefail

BAO_ADDR="${BAO_ADDR:-http://$(tailscale ip -4):8200}"
export BAO_ADDR
echo "Using BAO_ADDR=$BAO_ADDR"

# Check if already initialized
if bao status -format=json 2>/dev/null | jq -e '.initialized == true' > /dev/null 2>&1; then
  echo "ERROR: OpenBao is already initialized. Do not run this script again."
  exit 1
fi

echo ""
echo "=== Initializing OpenBao ==="
echo ""
echo "With KMS auto-unseal, these are RECOVERY keys (not unseal keys)."
echo "Recovery keys are for emergency operations only — OpenBao auto-unseals via KMS."
echo ""

# Initialize with 5 recovery shares, 3 required threshold
bao operator init -recovery-shares=5 -recovery-threshold=3

echo ""
echo "========================================"
echo "  SAVE THE RECOVERY KEYS AND ROOT TOKEN"
echo "========================================"
echo ""
echo "Recovery key storage plan (3-of-5 threshold):"
echo "  Share 1: 1Password vault"
echo "  Share 2: Bitwarden vault (different service)"
echo "  Share 3: Printed, physically stored"
echo "  Shares 4-5: Additional secure locations"
echo ""
echo "No single point of compromise — 3 keys needed for recovery."
echo ""
echo "=== Next Steps ==="
echo "1. Save the recovery keys to the locations above"
echo "2. Log in with the root token: export BAO_TOKEN=<root-token>"
echo "3. Create your admin user/policy"
echo "4. Enable audit logging: bao audit enable file file_path=/var/log/openbao/audit.log"
echo "5. Run teardown-root.sh to revoke the root token"
echo "6. Run validate-init.sh to verify the deployment"
