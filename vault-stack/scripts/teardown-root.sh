#!/bin/bash
# teardown-root.sh — Revoke the root token after initial setup
# Run this AFTER creating admin user/policy and enabling audit logging.
set -euo pipefail

BAO_ADDR="${BAO_ADDR:-http://$(tailscale ip -4):8200}"
export BAO_ADDR

if [ -z "${BAO_TOKEN:-}" ]; then
  echo "ERROR: BAO_TOKEN must be set to the root token."
  echo "Usage: export BAO_TOKEN=<root-token> && ./teardown-root.sh"
  exit 1
fi

echo "This will revoke the current root token."
echo "To generate a new root token later: bao operator generate-root"
echo ""
read -p "Are you sure? (yes/no): " confirm

if [ "$confirm" != "yes" ]; then
  echo "Aborted."
  exit 0
fi

bao token revoke -self
echo ""
echo "Root token revoked."
echo "To generate a new one: bao operator generate-root"
echo "This requires 3 of 5 recovery keys."
