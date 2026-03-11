# ocs-automation

Pulumi infrastructure for [OpenClaw](https://github.com/openclaw/openclaw) — an EC2-hosted Claude Code automation service for [open-chat-studio](https://github.com/dimagi/open-chat-studio).

OpenClaw listens for Slack mentions and GitHub webhooks, then spins up ephemeral session containers that run Claude Code against the OCS codebase.

## Architecture

```
Pulumi (infra/)
  └── EC2 instance (Ubuntu 24.04)
        └── Docker Compose (openclaw/)
              ├── openclaw        ← webhook receiver, task orchestrator
              ├── nginx           ← TLS termination
              └── socket-proxy    ← Docker API allowlist
                    └── Session containers (session/)
                          └── acpx → Claude Code → open-chat-studio repo
```

## Directory Structure

```
infra/          Pulumi resource definitions (EC2, IAM, S3, secrets)
openclaw/       OpenClaw Docker Compose config, nginx, skills
  skills/ocs/   OpenClaw skill: Slack/GitHub triggers, session-manager.sh
scripts/        bootstrap.sh (first boot), deploy.sh (ongoing updates)
session/        Session container Dockerfile and entrypoint
docs/           Plans and prompts
```

## Setup

See [SETUP.md](SETUP.md) for initial setup and ongoing maintenance instructions.
