# ocs-automation

Pulumi (Python) infrastructure for OpenClaw — an EC2-hosted Claude Code automation service for open-chat-studio.

## Architecture

3-layer system:
1. **Pulumi** (`infra/`) — provisions AWS resources (EC2, EIP, IAM, S3, Secrets Manager)
2. **EC2 host** — Ubuntu 24.04 LTS, OpenClaw + Postgres + Caddy as systemd services
3. **Session containers** — ephemeral Docker containers running Claude Code via `acpx`

## Commands

All ops use `invoke` via `uv run inv <task>`. Run `uv run inv --list` for the full list.

```bash
# Infrastructure
uv run inv up                      # Deploy / update infra (Pulumi)
uv run inv up --yes                # Skip confirmation
uv run inv preview                 # Preview changes without applying
uv run inv outputs                 # Show stack outputs (instance_id, public_ip, etc.)

# Config deploy (sync to running instance)
uv run inv deploy                  # Auto-resolves instance ID from Pulumi

# Remote ops
uv run inv ssh                     # SSM session to the instance
uv run inv status                  # Container status + active sessions
uv run inv logs                    # Gateway logs (last 100 lines)
uv run inv logs --follow           # Tail logs
uv run inv health                  # Gateway health check

# Secrets
uv run inv push-secrets            # Upload .env.prod to Secrets Manager
uv run inv push-github-key --pem-file=key.pem

# Backup & Restore
uv run inv backup                  # Backup config + DB to S3
uv run inv restore                 # Restore from latest S3 backup

# Lint
uv run inv lint                    # Check only
uv run inv fmt                     # Auto-fix + format
```

Raw Pulumi commands still work with the 1Password prefix:
```bash
op run --env-file=.pulumi.env -- pulumi config set domain <host>
```

## Key Files

| Path | Purpose |
|------|---------|
| `__main__.py` | Pulumi entry point — wires all resources |
| `infra/config.py` | Stack config, region, instance type, naming |
| `infra/ec2.py` | EC2 instance + EBS + EIP creation |
| `infra/secrets.py` | Secrets Manager placeholders (values set manually) |
| `scripts/bootstrap.sh` | Idempotent EC2 setup (re-runnable) |
| `scripts/deploy.sh` | Config/skills sync to running instance via SSM |
| `scripts/backup-to-s3.sh` | Backup OpenClaw config + Postgres to S3 |
| `scripts/restore-from-s3.sh` | Restore from latest S3 backup |
| `openclaw/Caddyfile` | Caddy reverse proxy config (auto TLS) |
| `openclaw/skills/ocs/skill.json` | OpenClaw skill triggers (Slack, GitHub, cron) |
| `openclaw/skills/ocs/session-manager.sh` | Launches session containers |
| `session/Dockerfile` | Session container image (Claude Code + acpx + uv) |
| `session/entrypoint.sh` | Session startup: clone repos, migrate, run acpx |

## Gotchas

- **Bootstrap is idempotent** — safe to re-run. Full rebuild: `pulumi destroy && pulumi up`.
- **`__DOMAIN__` is a template variable**: `infra/ec2.py` substitutes it at deploy time. Do not run `bootstrap.sh` directly; it will fail if the literal string is present.
- **Secrets must be set manually**: Pulumi creates empty Secrets Manager entries. You must `put-secret-value` after first deploy before OpenClaw will start correctly.
- **Postgres listens on localhost + Docker bridge (172.17.0.1)**. Session containers connect via `host.docker.internal`.
- **Default region**: `ap-southeast-2` — set explicitly in Pulumi config if deploying elsewhere.
- **Pulumi secrets via 1Password**: all Pulumi commands require `op run --env-file=.pulumi.env --` prefix to inject `PULUMI_BACKEND_URL` and `PULUMI_CONFIG_PASSPHRASE` from 1Password. See `.pulumi.env` for the item reference.
- **Task prompts via file**: Session containers read `TASK_PROMPT` from `/workspace/task-prompt.txt`, not an env var.

## Environment Setup

```bash
# Install deps
uv sync

# Required Pulumi config
pulumi config set domain openclaw.example.com
pulumi config set aws:region ap-southeast-2      # optional, default above
pulumi config set instance_type t3.large          # optional, default t3.large
```
