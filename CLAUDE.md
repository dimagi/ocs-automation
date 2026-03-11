# ocs-automation

Pulumi (Python) infrastructure for OpenClaw — an EC2-hosted Claude Code automation service for open-chat-studio.

## Architecture

4-layer system:
1. **Pulumi** (`infra/`) — provisions AWS resources (EC2, EBS, EIP, IAM, S3, Secrets Manager)
2. **EC2 host** — Ubuntu 24.04 LTS, bootstrapped once via `scripts/bootstrap.sh` user-data
3. **OpenClaw** (`openclaw/`) — Docker Compose app: openclaw + nginx + docker-socket-proxy
4. **Session containers** (`session/`) — ephemeral containers running Claude Code via `acpx`

## Commands

```bash
# Infrastructure (state in S3, passphrase in 1Password via .pulumi.env)
alias p="op run --env-file=.pulumi.env -- pulumi"  # convenience alias
p up                               # Deploy / update infra
p stack output                     # Show outputs (instance_id, public_ip, etc.)
p config set domain <host>         # Required before first deploy
p config set aws:region ap-southeast-2

# Config deploy (update OpenClaw config on running instance)
./scripts/deploy.sh <instance-id>  # Get instance-id from: pulumi stack output instance_id

# Set secrets after first deploy (values never in code)
aws secretsmanager put-secret-value \
    --secret-id ocs-automation/openclaw-env \
    --secret-string "$(cat .env.prod)"

# Lint
uv run ruff check .
uv run ruff format .
```

## Key Files

| Path | Purpose |
|------|---------|
| `__main__.py` | Pulumi entry point — wires all resources |
| `infra/config.py` | Stack config, region, instance type, naming |
| `infra/ec2.py` | EC2 instance + EBS + EIP creation |
| `infra/secrets.py` | Secrets Manager placeholders (values set manually) |
| `scripts/bootstrap.sh` | EC2 first-boot user-data (runs once) |
| `scripts/deploy.sh` | Config/skills sync to running instance via SSM |
| `openclaw/docker-compose.yml` | OpenClaw app stack |
| `openclaw/skills/ocs/skill.json` | OpenClaw skill triggers (Slack, GitHub, cron) |
| `openclaw/skills/ocs/session-manager.sh` | Launches session containers |
| `session/Dockerfile` | Session container image (Claude Code + acpx + uv) |
| `session/entrypoint.sh` | Session startup: clone repos, migrate, run acpx |

## Gotchas

- **Bootstrap runs once**: `user_data_replace_on_change=False` — `scripts/bootstrap.sh` only executes at first EC2 boot. Config/skills updates go through `./scripts/deploy.sh` (SSM).
- **`__DOMAIN__` is a template variable**: `infra/ec2.py` substitutes it at deploy time. Do not run `bootstrap.sh` directly; it will fail if the literal string is present.
- **Secrets must be set manually**: Pulumi creates empty Secrets Manager entries. You must `put-secret-value` after first deploy before OpenClaw will start correctly.
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
