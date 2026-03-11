# Simplified Architecture Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Docker-in-Docker OpenClaw architecture with native host services (OpenClaw, Postgres, Caddy) and Docker-only session containers.

**Architecture:** OpenClaw + PostgreSQL + Caddy run as systemd services on the EC2 host. Session containers are launched via `docker run` with `--add-host=host.docker.internal:host-gateway` for Postgres access. S3 backup/restore enables tear-down-and-rebuild recovery.

**Tech Stack:** Pulumi (Python), Bash, Docker, PostgreSQL 16, Caddy, Node.js 22+, systemd

**Spec:** `docs/specs/2026-03-11-simplified-architecture-design.md`

---

## Chunk 1: Infrastructure Changes (Pulumi)

### Task 1: Remove EBS data volume from Pulumi

Remove the separate 200GB EBS volume. Increase root volume to 150GB.

**Files:**
- Modify: `infra/ec2.py`
- Modify: `__main__.py`

- [ ] **Step 1: Read current ec2.py and __main__.py**

Understand current EBS volume creation, attachment, and exports.

- [ ] **Step 2: Remove EBS volume and attachment from ec2.py**

In `infra/ec2.py`:
- Delete the `aws.ebs.Volume` resource
- Delete the `aws.ec2.VolumeAttachment` resource
- Change root volume size from 100 to 150 in the `root_block_device`
- Remove any functions/variables related to the data volume

- [ ] **Step 3: Remove data volume exports from __main__.py**

In `__main__.py`:
- Remove `pulumi.export("data_volume_id", ...)`
- Remove any references to the data volume module

- [ ] **Step 4: Run `uv run inv lint` to verify no issues**

Expected: clean lint output.

- [ ] **Step 5: Commit**

```bash
git add infra/ec2.py __main__.py
git commit -m "infra: remove separate EBS data volume, increase root to 150GB"
```

---

### Task 2: Simplify bootstrap user-data in ec2.py

The bootstrap script will be completely rewritten (Task 5). For now, update ec2.py to:
- Set `user_data_replace_on_change=True` (idempotent bootstrap = safe to re-run)
- Keep the `__DOMAIN__` substitution pattern

**Files:**
- Modify: `infra/ec2.py`

- [ ] **Step 1: Change user_data_replace_on_change to True**

In `infra/ec2.py`, find `user_data_replace_on_change=False` and change to `True`.

- [ ] **Step 2: Commit**

```bash
git add infra/ec2.py
git commit -m "infra: enable user_data_replace_on_change for idempotent bootstrap"
```

---

## Chunk 2: Delete Old Docker Architecture Files

### Task 3: Remove Docker Compose and nginx files for OpenClaw

These files are replaced by native host services.

**Files:**
- Delete: `openclaw/docker-compose.yml`
- Delete: `openclaw/Dockerfile`
- Delete: `openclaw/nginx.conf`
- Delete: `openclaw/nginx-http.conf`
- Delete: `openclaw/nginx-https.conf` (if exists)
- Delete: `session/docker-compose.yml`

- [ ] **Step 1: Delete the files**

```bash
git rm openclaw/docker-compose.yml openclaw/Dockerfile openclaw/nginx.conf
git rm -f openclaw/nginx-http.conf openclaw/nginx-https.conf
git rm session/docker-compose.yml
```

- [ ] **Step 2: Commit**

```bash
git commit -m "chore: remove old Docker Compose, nginx, and Dockerfile files

Replaced by native host services (Caddy, systemd) per simplified architecture."
```

---

## Chunk 3: New Bootstrap Script

### Task 4: Write the Caddyfile

Simple reverse proxy config for GitHub webhooks.

**Files:**
- Create: `openclaw/Caddyfile`

- [ ] **Step 1: Create the Caddyfile**

```
# Domain is substituted by deploy script
__DOMAIN__ {
    reverse_proxy localhost:18789
}
```

OpenClaw gateway listens on 18789. Caddy handles TLS automatically via Let's Encrypt.

- [ ] **Step 2: Commit**

```bash
git add openclaw/Caddyfile
git commit -m "feat: add Caddyfile for automatic TLS reverse proxy"
```

---

### Task 5: Write the new idempotent bootstrap script

Replace the current 8-phase one-shot bootstrap with an idempotent script.

**Files:**
- Rewrite: `scripts/bootstrap.sh`

- [ ] **Step 1: Write the new bootstrap.sh**

The script must be idempotent (safe to re-run). It should:

**Phase 1 — System packages:**
```bash
# Add Docker CE repo
# Add Caddy repo (https://caddyserver.com/docs/install#debian-ubuntu-raspbian)
# Add NodeSource repo (Node.js 22)
# apt install: docker-ce docker-ce-cli containerd.io docker-compose-plugin
#              postgresql-16 postgresql-client-16
#              caddy
#              nodejs
#              git curl jq unzip
```

**Phase 2 — Tools:**
```bash
# Install uv (Python package manager)
curl -LsSf https://astral.sh/uv/install.sh | sh
# Install acpx
npm install -g @anthropic-ai/acpx@latest
# Install Claude Code
npm install -g @anthropic-ai/claude-code@latest
```

**Phase 3 — PostgreSQL configuration:**
```bash
# Create openclaw role with CREATEDB (idempotent)
sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname='openclaw'" | grep -q 1 \
  || sudo -u postgres createuser --createdb openclaw

# Add Docker bridge to pg_hba.conf (idempotent)
PG_HBA="/etc/postgresql/16/main/pg_hba.conf"
grep -q '172.17.0.0/16' "$PG_HBA" \
  || echo 'host all openclaw 172.17.0.0/16 trust' >> "$PG_HBA"

# Listen on Docker bridge in postgresql.conf (idempotent)
PG_CONF="/etc/postgresql/16/main/postgresql.conf"
sed -i "s/^#\?listen_addresses.*/listen_addresses = 'localhost,172.17.0.1'/" "$PG_CONF"

systemctl restart postgresql
```

**Phase 4 — Directory structure:**
```bash
mkdir -p /opt/openclaw/{config,memory,skills}
mkdir -p /opt/ocs-automation
mkdir -p /data/sessions
```

**Phase 5 — Application deployment:**
```bash
# Clone or update ocs-automation repo
if [ -d /opt/ocs-automation/.git ]; then
    git -C /opt/ocs-automation pull --ff-only
else
    git clone https://github.com/dimagi/ocs-automation.git /opt/ocs-automation
fi

# Copy skills to OpenClaw directory
cp -r /opt/ocs-automation/openclaw/skills/* /opt/openclaw/skills/

# Copy and configure Caddyfile
cp /opt/ocs-automation/openclaw/Caddyfile /etc/caddy/Caddyfile
sed -i "s/__DOMAIN__/${DOMAIN}/g" /etc/caddy/Caddyfile
systemctl reload caddy
```

**Phase 6 — Secrets injection:**
```bash
# Fetch region from IMDS v2
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/region)

# Fetch .env from Secrets Manager
aws secretsmanager get-secret-value \
  --region "$REGION" \
  --secret-id ocs-automation/openclaw-env \
  --query SecretString --output text > /opt/openclaw/.env
chmod 600 /opt/openclaw/.env
```

**Phase 7 — OpenClaw installation:**
```bash
# Install OpenClaw globally
npm install -g openclaw@latest

# Install daemon (creates systemd service)
# openclaw onboard --install-daemon handles this
# If already installed, this is a no-op
openclaw onboard --install-daemon --config-dir /opt/openclaw/config --env-file /opt/openclaw/.env
systemctl enable openclaw-gateway
systemctl restart openclaw-gateway
```

**Phase 8 — S3 restore (if backup exists):**
```bash
BUCKET=$(aws s3 ls | grep ocs-automation | awk '{print $3}')
if aws s3 ls "s3://${BUCKET}/backups/latest/" 2>/dev/null; then
    echo "Restoring from S3 backup..."
    aws s3 sync "s3://${BUCKET}/backups/latest/openclaw/" /opt/openclaw/ --exclude ".env"
    # Restore Postgres dumps if they exist
    for dump in /opt/openclaw/backups/*.sql; do
        [ -f "$dump" ] && sudo -u postgres psql < "$dump"
    done
    systemctl restart openclaw-gateway
fi
```

**Phase 9 — Build session container image:**
```bash
docker build -t ocs-session /opt/ocs-automation/session/
```

**Phase 10 — S3 backup timer:**
```bash
# Create backup script
cat > /opt/ocs-automation/scripts/run-backup.sh << 'BACKUP'
#!/bin/bash
BUCKET=$(aws s3 ls | grep ocs-automation | awk '{print $3}')
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
# Backup OpenClaw config and memory
aws s3 sync /opt/openclaw/config/ "s3://${BUCKET}/backups/${TIMESTAMP}/openclaw/config/"
aws s3 sync /opt/openclaw/memory/ "s3://${BUCKET}/backups/${TIMESTAMP}/openclaw/memory/"
aws s3 sync /opt/openclaw/skills/ "s3://${BUCKET}/backups/${TIMESTAMP}/openclaw/skills/"
# Postgres dump
pg_dump -U openclaw --format=custom -f "/tmp/openclaw-backup.dump" openclaw 2>/dev/null
[ -f /tmp/openclaw-backup.dump ] && aws s3 cp /tmp/openclaw-backup.dump "s3://${BUCKET}/backups/${TIMESTAMP}/openclaw/backups/"
# Update latest pointer
aws s3 sync "s3://${BUCKET}/backups/${TIMESTAMP}/" "s3://${BUCKET}/backups/latest/"
BACKUP
chmod +x /opt/ocs-automation/scripts/run-backup.sh

# Create systemd timer (idempotent)
cat > /etc/systemd/system/openclaw-backup.service << 'SVC'
[Unit]
Description=OpenClaw S3 Backup

[Service]
Type=oneshot
ExecStart=/opt/ocs-automation/scripts/run-backup.sh
SVC

cat > /etc/systemd/system/openclaw-backup.timer << 'TIMER'
[Unit]
Description=OpenClaw S3 Backup Timer

[Timer]
OnCalendar=*-*-* 00/4:00:00
Persistent=true

[Install]
WantedBy=timers.target
TIMER

systemctl daemon-reload
systemctl enable --now openclaw-backup.timer
```

The full script should be wrapped with:
```bash
#!/bin/bash
set -euo pipefail
exec > >(tee -a /var/log/bootstrap.log) 2>&1
echo "=== Bootstrap started at $(date) ==="

# ... phases ...

echo "=== Bootstrap completed at $(date) ==="
```

- [ ] **Step 2: Verify the script is syntactically valid**

```bash
bash -n scripts/bootstrap.sh
```

- [ ] **Step 3: Commit**

```bash
git add scripts/bootstrap.sh
git commit -m "feat: rewrite bootstrap as idempotent script

Replaces one-shot bootstrap with re-runnable setup:
- Native OpenClaw, Postgres 16, Caddy (no Docker Compose)
- S3 backup/restore for config and memory
- systemd timer for periodic backups"
```

---

## Chunk 4: Session Container Updates

### Task 6: Simplify session Dockerfile

Remove Redis references. Add `--add-host` documentation. The Dockerfile itself stays mostly the same but we should verify it doesn't reference the old docker-compose network.

**Files:**
- Modify: `session/Dockerfile`

- [ ] **Step 1: Read current session/Dockerfile**

Verify contents and identify any references to the old compose network or Redis.

- [ ] **Step 2: Update if needed**

The Dockerfile should be self-contained. Remove any compose-specific ENV vars or references. Ensure `postgresql-client` is installed (for migrations against host Postgres).

- [ ] **Step 3: Commit (if changes were made)**

```bash
git add session/Dockerfile
git commit -m "chore: clean up session Dockerfile for standalone docker run"
```

---

### Task 7: Update session entrypoint

Update `session/entrypoint.sh` to work with host Postgres via `DATABASE_URL` environment variable instead of expecting a compose-linked `db` service.

**Files:**
- Modify: `session/entrypoint.sh`

- [ ] **Step 1: Read current session/entrypoint.sh**

Identify how it currently connects to Postgres and Redis.

- [ ] **Step 2: Update Postgres connection**

Replace any hardcoded `db` hostname references with `DATABASE_URL` from environment.
The `pg_isready` wait loop should use the host from `DATABASE_URL` (which will be `host.docker.internal`).

Change:
```bash
# Old: wait for compose-linked 'db' service
until pg_isready -h db -U postgres; do sleep 1; done
```

To:
```bash
# Extract host and port from DATABASE_URL
DB_HOST=$(python3 -c "from urllib.parse import urlparse; print(urlparse('${DATABASE_URL}').hostname)")
DB_PORT=$(python3 -c "from urllib.parse import urlparse; print(urlparse('${DATABASE_URL}').port or 5432)")
until pg_isready -h "$DB_HOST" -p "$DB_PORT"; do sleep 1; done
```

- [ ] **Step 3: Remove Redis dependency**

Remove any Redis wait loops or connection checks. Add `CACHE_BACKEND=django.core.cache.backends.dummy.DummyCache` to the environment if not already set.

- [ ] **Step 4: Commit**

```bash
git add session/entrypoint.sh
git commit -m "feat: update session entrypoint for host Postgres, remove Redis"
```

---

### Task 8: Rewrite session-manager.sh

Replace the Docker Compose orchestration with simple `docker run`. Remove file locking. Add database create/drop.

**Files:**
- Rewrite: `openclaw/skills/ocs/session-manager.sh`

- [ ] **Step 1: Write new session-manager.sh**

```bash
#!/bin/bash
set -euo pipefail

ACTION="${1:?Usage: session-manager.sh <action> <task_id> <prompt>}"
TASK_ID="${2:?Missing task_id}"
PROMPT="${3:?Missing prompt}"

# Validate task ID
if [[ ! "$TASK_ID" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "ERROR: Invalid TASK_ID: $TASK_ID" >&2
    exit 1
fi

SESSION_DIR="/data/sessions/session-${TASK_ID}"
mkdir -p "$SESSION_DIR"

# Write task prompt to file (avoid env var exposure in docker inspect)
echo "$PROMPT" > "$SESSION_DIR/task-prompt.txt"
chmod 600 "$SESSION_DIR/task-prompt.txt"

# Create session database
DB_NAME="session_${TASK_ID}"
createdb -U openclaw "$DB_NAME" 2>/dev/null || echo "Database $DB_NAME already exists"

# Source environment for API keys
source /opt/openclaw/.env

# Run session container
docker run --rm \
    --name "session-${TASK_ID}" \
    --add-host=host.docker.internal:host-gateway \
    -e "TASK_ID=${TASK_ID}" \
    -e "DATABASE_URL=postgresql://openclaw@host.docker.internal:5432/${DB_NAME}" \
    -e "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}" \
    -e "DJANGO_SETTINGS_MODULE=open_chat_studio.settings" \
    -e "CACHE_BACKEND=django.core.cache.backends.dummy.DummyCache" \
    -v "${SESSION_DIR}:/workspace" \
    ocs-session

EXIT_CODE=$?

# Drop session database
dropdb -U openclaw "$DB_NAME" 2>/dev/null || echo "Database $DB_NAME already dropped"

# Report output
if [ -f "$SESSION_DIR/output.json" ]; then
    cat "$SESSION_DIR/output.json"
fi

exit $EXIT_CODE
```

- [ ] **Step 2: Update skill.json to remove lock_file**

In `openclaw/skills/ocs/skill.json`, remove the `lock_file` and `lock_timeout` fields from the session manager config.

- [ ] **Step 3: Commit**

```bash
git add openclaw/skills/ocs/session-manager.sh openclaw/skills/ocs/skill.json
git commit -m "feat: rewrite session-manager for docker run + host Postgres

- No more Docker Compose per session
- Creates/drops Postgres database per session
- No file locking (concurrent sessions supported)
- Connects to host Postgres via host.docker.internal"
```

---

## Chunk 5: Deploy Script & Invoke Tasks

### Task 9: Rewrite deploy script for native host

The deploy script needs to sync files and restart native services instead of Docker Compose.

**Files:**
- Rewrite: `scripts/deploy.sh`

- [ ] **Step 1: Read current deploy.sh**

Understand S3 staging + SSM command pattern.

- [ ] **Step 2: Rewrite deploy.sh**

Keep the S3 staging + SSM pattern but change the on-instance commands:

```bash
# On-instance commands (sent via SSM):
# 1. Sync from S3
aws s3 sync "s3://${BUCKET}/deploy/" /opt/ocs-automation/ --delete

# 2. Update skills
cp -r /opt/ocs-automation/openclaw/skills/* /opt/openclaw/skills/

# 3. Update Caddyfile
cp /opt/ocs-automation/openclaw/Caddyfile /etc/caddy/Caddyfile
DOMAIN=$(grep DOMAIN /opt/openclaw/.env | cut -d= -f2)
sed -i "s/__DOMAIN__/${DOMAIN}/g" /etc/caddy/Caddyfile
systemctl reload caddy

# 4. Rebuild session image
docker build -t ocs-session /opt/ocs-automation/session/

# 5. Restart OpenClaw
systemctl restart openclaw-gateway
```

- [ ] **Step 3: Commit**

```bash
git add scripts/deploy.sh
git commit -m "feat: update deploy script for native host services"
```

---

### Task 10: Write backup and restore scripts

**Files:**
- Create: `scripts/backup-to-s3.sh`
- Create: `scripts/restore-from-s3.sh`

- [ ] **Step 1: Write backup-to-s3.sh**

```bash
#!/bin/bash
set -euo pipefail

# Determine bucket from Pulumi or env
BUCKET="${BACKUP_BUCKET:-$(aws s3 ls | grep ocs-automation | head -1 | awk '{print $3}')}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
PREFIX="backups/${TIMESTAMP}"

echo "Backing up to s3://${BUCKET}/${PREFIX}/"

# OpenClaw config and memory
aws s3 sync /opt/openclaw/config/ "s3://${BUCKET}/${PREFIX}/openclaw/config/"
aws s3 sync /opt/openclaw/memory/ "s3://${BUCKET}/${PREFIX}/openclaw/memory/"
aws s3 sync /opt/openclaw/skills/ "s3://${BUCKET}/${PREFIX}/openclaw/skills/"

# Postgres dump (non-session databases only)
sudo -u postgres pg_dumpall --exclude-database='session_*' --format=plain \
    -f /tmp/openclaw-pg-backup.sql 2>/dev/null || true
if [ -f /tmp/openclaw-pg-backup.sql ]; then
    aws s3 cp /tmp/openclaw-pg-backup.sql "s3://${BUCKET}/${PREFIX}/postgres/"
    rm /tmp/openclaw-pg-backup.sql
fi

# Update latest symlink
aws s3 sync "s3://${BUCKET}/${PREFIX}/" "s3://${BUCKET}/backups/latest/" --delete

echo "Backup complete: s3://${BUCKET}/${PREFIX}/"
```

- [ ] **Step 2: Write restore-from-s3.sh**

```bash
#!/bin/bash
set -euo pipefail

BUCKET="${BACKUP_BUCKET:-$(aws s3 ls | grep ocs-automation | head -1 | awk '{print $3}')}"
PREFIX="${1:-backups/latest}"

echo "Restoring from s3://${BUCKET}/${PREFIX}/"

# Restore OpenClaw config and memory (preserve .env)
aws s3 sync "s3://${BUCKET}/${PREFIX}/openclaw/config/" /opt/openclaw/config/
aws s3 sync "s3://${BUCKET}/${PREFIX}/openclaw/memory/" /opt/openclaw/memory/
aws s3 sync "s3://${BUCKET}/${PREFIX}/openclaw/skills/" /opt/openclaw/skills/

# Restore Postgres (if dump exists)
DUMP="/tmp/openclaw-pg-restore.sql"
if aws s3 cp "s3://${BUCKET}/${PREFIX}/postgres/openclaw-pg-backup.sql" "$DUMP" 2>/dev/null; then
    sudo -u postgres psql < "$DUMP"
    rm "$DUMP"
    echo "Postgres restored."
fi

# Restart services
systemctl restart openclaw-gateway

echo "Restore complete."
```

- [ ] **Step 3: Commit**

```bash
git add scripts/backup-to-s3.sh scripts/restore-from-s3.sh
git commit -m "feat: add S3 backup and restore scripts"
```

---

### Task 11: Update invoke tasks

Update `tasks.py` to reflect the new architecture (no Docker Compose commands on remote).

**Files:**
- Modify: `tasks.py`

- [ ] **Step 1: Read current tasks.py**

Identify which tasks reference Docker Compose or old architecture.

- [ ] **Step 2: Update remote ops tasks**

- `status`: Change from `docker compose ps` to `systemctl status openclaw-gateway caddy postgresql` + `docker ps` (for sessions)
- `logs`: Change from `docker compose logs` to `journalctl -u openclaw-gateway`
- `health`: Change from `docker compose run openclaw-cli doctor` to `openclaw doctor` (native)
- Keep: `up`, `preview`, `outputs`, `deploy`, `ssh`, `push-secrets`, `push-github-key`, `lint`, `fmt`

- [ ] **Step 3: Add backup/restore tasks**

```python
@task
def backup(c):
    """Trigger S3 backup on the instance."""
    instance_id = _get_instance_id(c)
    _run_ssm(c, instance_id, "/opt/ocs-automation/scripts/backup-to-s3.sh")

@task
def restore(c, timestamp="latest"):
    """Restore from S3 backup."""
    instance_id = _get_instance_id(c)
    _run_ssm(c, instance_id, f"/opt/ocs-automation/scripts/restore-from-s3.sh backups/{timestamp}")
```

- [ ] **Step 4: Commit**

```bash
git add tasks.py
git commit -m "feat: update invoke tasks for native host architecture"
```

---

## Chunk 6: Documentation Updates

### Task 12: Update CLAUDE.md and README

Update project docs to reflect the new architecture.

**Files:**
- Modify: `CLAUDE.md`
- Modify: `README.md` (if exists)
- Modify: `SETUP.md` (if exists)

- [ ] **Step 1: Update CLAUDE.md**

Change the Architecture section from 4-layer to 3-layer. Update Key Files table. Update Gotchas section (remove one-shot bootstrap, DinD references). Add backup/restore commands.

- [ ] **Step 2: Update README.md and SETUP.md**

Remove Docker Compose references. Update setup instructions for native install. Add backup/restore documentation.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md README.md SETUP.md
git commit -m "docs: update documentation for simplified architecture"
```

---

## Task Dependency Summary

```
Task 1 (remove EBS) ─┐
Task 2 (user_data)  ──┤
Task 3 (delete files) ┤
Task 4 (Caddyfile)  ──┼── can run in parallel (no dependencies)
Task 6 (Dockerfile) ──┤
Task 7 (entrypoint) ──┘
                       │
Task 5 (bootstrap) ────┤── depends on Task 4 (Caddyfile path)
                       │
Task 8 (session-mgr) ──┤── depends on Task 7 (entrypoint changes)
                       │
Task 9 (deploy.sh) ────┤── depends on Task 5 (bootstrap pattern)
Task 10 (backup) ──────┤── independent
                       │
Task 11 (tasks.py) ────┤── depends on Task 9 (deploy changes)
Task 12 (docs) ────────┘── last (reflects all changes)
```
