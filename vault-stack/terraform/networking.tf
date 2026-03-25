# --- Security Group (no inbound, scoped outbound) ---

resource "aws_security_group" "vault" {
  name        = "vault-instance"
  description = "Vault EC2 — no inbound, scoped outbound"
  vpc_id      = var.vpc_id

  # No ingress rules — Vault is accessed exclusively via Tailscale
  # Tailscale establishes outbound connections; return traffic via stateful tracking

  # HTTPS — AWS API calls (KMS, S3, SSM, STS, CloudWatch), Tailscale coordination
  egress {
    description = "HTTPS to AWS APIs and Tailscale coordination"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTP — package manager updates (apt), HashiCorp releases
  egress {
    description = "HTTP for package updates"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # DNS (UDP)
  egress {
    description = "DNS UDP"
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # DNS (TCP) — fallback for large DNS responses
  egress {
    description = "DNS TCP"
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # NTP — time synchronization (critical for TLS, Vault leases, AWS SigV4)
  egress {
    description = "NTP"
    from_port   = 123
    to_port     = 123
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Tailscale WireGuard — direct peer connections
  egress {
    description = "Tailscale WireGuard"
    from_port   = 41641
    to_port     = 41641
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Tailscale STUN — NAT traversal for direct connections
  egress {
    description = "Tailscale STUN"
    from_port   = 3478
    to_port     = 3478
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "vault-instance"
  }
}

# --- S3 VPC Gateway Endpoint (free, keeps S3 traffic on AWS network) ---

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [var.route_table_id]

  tags = {
    Name = "vault-s3-endpoint"
  }
}
