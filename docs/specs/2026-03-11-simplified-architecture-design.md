# Simplified Architecture Design

**Date:** 2026-03-11
**Status:** Approved

## Problem

The current Docker-in-Docker architecture (OpenClaw in Docker, spawning session containers through a socket proxy) has proven difficult to bootstrap and debug. Three days of troubleshooting without a fully working setup. The one-shot bootstrap model makes recovery from failures extremely painful.

## Decision

Run OpenClaw natively on the EC2 host. Use Docker only for session container isolation. Replace nginx + certbot with Caddy (automatic TLS). Replace per-session Postgres/Redis containers with a shared host Postgres instance.

## Architecture Overview

3-layer system (down from 4):

1. **Pulumi** (`infra/`) — provisions AWS resources (EC2, EIP, IAM, S3, Secrets Manager)
2. **EC2 host** — Ubuntu 24.04 LTS, OpenClaw + Postgres + Caddy as systemd services
3. **Session containers** — ephemeral Docker containers running Claude Code via acpx

### What's removed

- Docker Compose for OpenClaw gateway (no more DinD)
- Docker socket proxy (`tecnativa/docker-socket-proxy`)
- Custom OpenClaw Dockerfile (no more layering Docker CLI into OpenClaw image)
- nginx + certbot (replaced by Caddy)
- Separate EBS data volume (use root volume, resized to ~150GB)
- Per-session Postgres and Redis containers
- Per-session `docker-compose.yml` (replaced by single `docker run`)
- File-based session locking (concurrent sessions supported — each gets its own database)

## Infrastructure (Pulumi)

Keep existing Pulumi layer with simplifications:

**Retained:**
- EC2 instance (Ubuntu 24.04, t3.large) with Elastic IP
- IAM role with SSM + Secrets Manager + S3 access
- Security group: HTTP/HTTPS inbound (GitHub webhooks + Caddy TLS challenges), all outbound
- S3 bucket for artifacts + backups
- Secrets Manager for env vars + GitHub app key

**Removed:**
- Separate 200GB EBS data volume — root volume resized to ~150GB

**Changed:**
- Bootstrap script is idempotent (re-runnable). No more `user_data_replace_on_change=False`.
- Full rebuild: `pulumi destroy && pulumi up`.

## Host Setup (Bootstrap)

Idempotent script — safe to re-run at any time.

### Phase 1 — System packages
- Docker CE, PostgreSQL 16, Caddy, Node.js, jq, git, uv

### Phase 2 — PostgreSQL
- systemd service (`postgresql.service`)
- `openclaw` role with `CREATEDB` privilege (not superuser — only needs to create/drop session databases)
- Listens on localhost + Docker bridge gateway (`172.17.0.1`) so session containers can connect
- `pg_hba.conf`: trust from localhost, md5 from Docker subnet (`172.17.0.0/16`)

### Phase 3 — OpenClaw
- Installed via `npm install -g openclaw@latest` (requires Node.js ≥22)
- Daemon installed via `openclaw onboard --install-daemon` (creates its own systemd service)
- Config at `/opt/openclaw/` (config, skills, memory)
- Environment from Secrets Manager → `/opt/openclaw/.env`

### Phase 4 — Caddy
- systemd service (ships with unit file)
- Reverse proxy to OpenClaw's HTTP port for GitHub webhooks
- Automatic TLS via Let's Encrypt — no certbot, no cron

### Phase 5 — S3 Backup Cron
- systemd timer, every 4 hours
- Backs up: OpenClaw config/memory, `pg_dump` of persistent databases
- Restore script pulls from S3 and loads everything back

### Phase 6 — Docker (sessions only)
- Docker CE installed, no compose stacks at boot
- Session container image pre-built during bootstrap

## Session Containers

Each session is a single Docker container launched via `docker run`.

### Container contents
- Ubuntu base + Node.js + uv + Claude Code + acpx
- Git, PostgreSQL client tools

### Session lifecycle
1. OpenClaw receives trigger (Slack socket mode / GitHub webhook / cron)
2. Creates fresh Postgres database: `createdb session_<task_id>`
3. Runs `docker run` with:
   - `--add-host=host.docker.internal:host-gateway` for host Postgres access
   - Task prompt mounted as file
   - Workspace volume at `/data/sessions/<task_id>/`
   - Environment: `DATABASE_URL=postgresql://openclaw:<pw>@host.docker.internal:5432/session_<task_id>`, `ANTHROPIC_API_KEY`, repo URLs
4. Inside container:
   - Clone/update OCS repos
   - Run Django migrations against session database
   - Start acpx, connect to OpenClaw gateway via ACP (WebSocket)
   - Claude Code executes task
   - Output written to workspace volume
5. Container exits
6. Drop session database: `dropdb session_<task_id>`
7. Workspace persists on host for audit

### Redis replacement
- Django dummy cache backend in session environment (no Redis needed)
- **Open question:** If OCS uses Redis for Celery broker or Django Channels, sessions may need a Redis instance. Deferred — will evaluate during implementation and add a shared Redis container if needed.

### Migration from current architecture
- No incremental migration path. `pulumi destroy` the current stack, then `pulumi up` with the new config.
- Old `openclaw/docker-compose.yml`, `openclaw/Dockerfile`, `openclaw/nginx.conf` will be deleted from the repo.

## S3 Backup & Recovery

### Backed up (every 4 hours)
- `/opt/openclaw/config/` — gateway config, agent definitions
- `/opt/openclaw/memory/` — persistent memory/context
- `/opt/openclaw/skills/` — skill definitions
- `pg_dump` of persistent databases (not ephemeral session DBs)

### Destination
S3 artifacts bucket under `backups/` prefix with timestamp.

### Recovery flows

**Full rebuild:**
1. `pulumi destroy && pulumi up`
2. Bootstrap installs everything
3. Bootstrap pulls latest backup from S3
4. Restores config/memory + DB data
5. OpenClaw starts with previous state (~5 minutes total)

**Manual recovery (existing instance):**
- SSM in, run `restore-from-s3.sh`

Secrets Manager values persist across destroy/up cycles (set out of band).

## File Layout

```
/opt/openclaw/
├── .env                    # From Secrets Manager at boot
├── config/                 # Gateway config, agent definitions
├── memory/                 # Persistent memory/context
├── skills/
│   └── ocs/
│       ├── skill.json      # Triggers (Slack, GitHub, cron)
│       └── session-manager.sh
└── Caddyfile               # Reverse proxy config

/opt/ocs-automation/        # Git clone of this repo
├── session/
│   ├── Dockerfile
│   └── entrypoint.sh
└── scripts/
    ├── bootstrap.sh        # Idempotent setup
    ├── backup-to-s3.sh
    └── restore-from-s3.sh

/data/sessions/             # Session workspaces (persist for audit)
└── session-<task_id>/
    ├── task-prompt.txt
    ├── output.json
    └── app/
```

### Systemd services
- `postgresql.service` (system default)
- `openclaw-gateway.service` (custom unit)
- `caddy.service` (ships with Caddy)
- `openclaw-backup.timer` (S3 backup every 4 hours)

## External Connectivity

- **Slack:** Socket Mode (outbound WebSocket) — no public endpoint needed
- **GitHub webhooks:** Inbound HTTPS via Caddy reverse proxy to OpenClaw
- **SSM:** Outbound to AWS Systems Manager — no SSH, no port 22

## Repo structure (`ocs-automation/`)

- `infra/` — Pulumi (simplified)
- `scripts/` — bootstrap, backup, restore
- `session/` — Dockerfile + entrypoint for session containers
- `openclaw/` — skill definitions, Caddyfile (deployed to `/opt/openclaw/` via `deploy.sh`)
- `tasks.py` — invoke tasks

### Files to delete (from current architecture)
- `openclaw/docker-compose.yml`
- `openclaw/Dockerfile`
- `openclaw/nginx.conf`
- `openclaw/nginx-http.conf`
- `session/docker-compose.yml`
