# openbao.hcl — OpenBao server configuration (reference template)
#
# This file is NOT used directly. user-data.sh writes the actual config
# to /etc/openbao/openbao.hcl with runtime values (Tailscale IP, KMS key ID).
# Kept here as a reference for the expected configuration shape.

ui = true

listener "tcp" {
  address     = "<tailscale-ip>:8200"
  tls_disable = true  # Tailscale WireGuard handles encryption
}

storage "raft" {
  path    = "/opt/openbao/data"
  node_id = "openbao-1"
}

seal "awskms" {
  region     = "ap-south-1"
  kms_key_id = "<kms-key-id>"  # Templated by user-data
}

api_addr     = "http://<tailscale-ip>:8200"
cluster_addr = "http://<tailscale-ip>:8201"

telemetry {
  disable_hostname          = true
  prometheus_retention_time = "12h"
}
