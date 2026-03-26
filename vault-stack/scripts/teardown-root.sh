#!/bin/bash
# teardown-root.sh — Revoke the root token after initial setup
# Run this AFTER creating admin user/policy and enabling audit logging.
set -euo pipefail

VAULT_ADDR="${VAULT_ADDR:-http://$(tailscale ip -4):8200}"
export VAULT_ADDR

if [ -z "${VAULT_TOKEN:-}" ]; then
  echo "ERROR: VAULT_TOKEN must be set to the root token."
  echo "Usage: export VAULT_TOKEN=<root-token> && ./teardown-root.sh"
  exit 1
fi

echo "This will revoke the current root token."
echo "To generate a new root token later: vault operator generate-root"
echo ""
read -p "Are you sure? (yes/no): " confirm

if [ "$confirm" != "yes" ]; then
  echo "Aborted."
  exit 0
fi

vault token revoke -self
echo ""
echo "Root token revoked."
echo "To generate a new one: vault operator generate-root"
echo "This requires 3 of 5 recovery keys."
