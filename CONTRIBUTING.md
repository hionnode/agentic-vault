# Contributing to Agentic Vault

Thanks for your interest in contributing. This project is early-stage — infrastructure (Phases 1-6) is built, and the higher-level integration layers are planned.

## Where Contributions Are Most Welcome

- **OpenBao MCP server** (Phase 8) — the highest-impact component for the agentic coding community
- **Policy templates** — reusable OpenBao policies for common agent patterns
- **Consumer integrations** — wrapper scripts and configs for additional agent platforms
- **Documentation improvements** — typos, clarifications, additional examples
- **Bug reports** — especially around Terraform configs or scripts

## How to Contribute

1. **Open an issue first** for anything beyond a typo fix. This avoids wasted effort on PRs that don't align with the project direction.
2. Fork the repo and create a branch from `main`.
3. Keep PRs focused on a single phase or component.
4. Submit a pull request with a clear description of what changed and why.

## Development Setup

You'll need your own infrastructure to test changes:

- **AWS account** with permissions to create IAM, KMS, S3, EC2, CloudWatch, SNS, SSM resources
- **Tailscale account** with a tailnet (free tier works)
- **Terraform** >= 1.10
- **AWS CLI** v2

See Phase 0 in the [implementation plan](implementation-plan.md) for detailed prerequisites.

## Code Style

- **Terraform:** Run `terraform fmt` before committing. Use meaningful variable descriptions.
- **Shell scripts:** Must pass `shellcheck`. Use `set -euo pipefail` at the top.
- **Documentation:** Keep ASCII diagrams where they exist. Avoid screenshots — they can't be searched or diffed.

## Security

- Never commit credentials, tokens, `.env` files, or `terraform.tfvars`
- Never create long-lived IAM access keys in examples or scripts
- Never use wildcard OpenBao policies unless there's no alternative

If you discover a security vulnerability, please report it privately by emailing the maintainer rather than opening a public issue.

## License

By contributing, you agree that your contributions will be licensed under the [MPL-2.0 License](LICENSE).
