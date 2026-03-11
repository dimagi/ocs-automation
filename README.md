# ocs-automation

Pulumi infrastructure for [OpenClaw](https://github.com/openclaw/openclaw) — an EC2-hosted Claude Code automation service for [open-chat-studio](https://github.com/dimagi/open-chat-studio).

OpenClaw listens for Slack mentions and GitHub webhooks, then spins up ephemeral session containers that run Claude Code against the OCS codebase.

## Architecture

```
Pulumi (infra/)
  └── EC2 instance (Ubuntu 24.04)
        ├── OpenClaw          ← webhook receiver, task orchestrator (systemd)
        ├── PostgreSQL 16     ← shared database (systemd)
        ├── Caddy             ← reverse proxy, automatic TLS (systemd)
        └── Docker
              └── Session containers (session/)
                    └── acpx → Claude Code → open-chat-studio repo
```

## Directory Structure

```
infra/          Pulumi resource definitions (EC2, IAM, S3, secrets)
openclaw/       Caddyfile, skills, config (deployed to /opt/openclaw/)
  skills/ocs/   OpenClaw skill: Slack/GitHub triggers, session-manager.sh
scripts/        bootstrap.sh (idempotent), deploy.sh, backup/restore
session/        Session container Dockerfile and entrypoint
docs/           Plans and specs
```

## Setup

See [SETUP.md](SETUP.md) for initial setup and ongoing maintenance instructions.
