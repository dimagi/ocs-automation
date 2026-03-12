#!/bin/bash
# scripts/bootstrap.sh
# Idempotent EC2 setup for OpenClaw automation instance.
# Safe to re-run — every phase uses guards to skip already-completed steps.
#
# Template variables replaced by infra/ec2.py before embedding as user-data:
#   __DOMAIN__  → the public hostname for Caddy TLS, set via: pulumi config set domain <host>
set -euo pipefail

DOMAIN="__DOMAIN__"

exec > >(tee -a /var/log/bootstrap.log) 2>&1
echo "=== Bootstrap started at $(date) ==="

# cloud-init doesn't set HOME; required by uv, npm, and other installers
export HOME=/root
export DEBIAN_FRONTEND=noninteractive

# Split the placeholder so Pulumi's replace() doesn't substitute inside the guard
_PLACEHOLDER='__DOMA'"IN__"
if [ -z "$DOMAIN" ] || [ "$DOMAIN" = "$_PLACEHOLDER" ]; then
    echo "ERROR: DOMAIN is not set. Ensure pulumi config set domain <your-domain> before deploying." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Phase 1 — System packages
# ---------------------------------------------------------------------------
echo "=== Phase 1: System packages ==="

# Prerequisites
apt-get update -y
apt-get install -y ca-certificates curl gnupg lsb-release software-properties-common

install -m 0755 -d /etc/apt/keyrings

# Docker CE repo (idempotent — skip if list file exists)
if [ ! -f /etc/apt/sources.list.d/docker.list ]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
        > /etc/apt/sources.list.d/docker.list
fi

# Caddy — install binary directly (apt repo GPG key has expired)
mkdir -p /etc/caddy
if ! command -v caddy &>/dev/null; then
    curl -sL "https://caddyserver.com/api/download?os=linux&arch=amd64" -o /usr/bin/caddy
    chmod +x /usr/bin/caddy
    groupadd --system caddy 2>/dev/null || true
    useradd --system --gid caddy --create-home --home-dir /var/lib/caddy --shell /usr/sbin/nologin caddy 2>/dev/null || true
fi
if [ ! -f /etc/systemd/system/caddy.service ]; then
    curl -sL "https://raw.githubusercontent.com/caddyserver/dist/master/init/caddy.service" \
        -o /etc/systemd/system/caddy.service
    systemctl daemon-reload
    systemctl enable caddy
fi

# NodeSource repo for Node.js 22 (idempotent — skip if list file exists)
if [ ! -f /etc/apt/sources.list.d/nodesource.list ]; then
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
fi

apt-get update -y
apt-get install -y \
    docker-ce docker-ce-cli containerd.io docker-compose-plugin \
    postgresql postgresql-client \
    nodejs \
    git curl jq unzip

systemctl enable docker
systemctl start docker

# AWS CLI v2 (idempotent — skip if already installed)
if ! command -v aws &>/dev/null; then
    curl -sL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
    cd /tmp && unzip -qo awscliv2.zip && ./aws/install
    cd -
fi

echo "Phase 1 complete."

# ---------------------------------------------------------------------------
# Phase 2 — Tools
# ---------------------------------------------------------------------------
echo "=== Phase 2: Tools ==="

# uv (Python package manager)
if ! command -v uv &>/dev/null; then
    curl -LsSf https://astral.sh/uv/install.sh | sh
    # Ensure uv is on PATH for the rest of the script
    export PATH="/root/.local/bin:$PATH"
else
    echo "uv already installed, skipping."
fi

# acpx
if ! npm list -g acpx &>/dev/null; then
    npm install -g acpx@latest
else
    echo "acpx already installed, updating."
    npm install -g acpx@latest
fi

# Claude Code
if ! npm list -g @anthropic-ai/claude-code &>/dev/null; then
    npm install -g @anthropic-ai/claude-code@latest
else
    echo "claude-code already installed, updating."
    npm install -g @anthropic-ai/claude-code@latest
fi

echo "Phase 2 complete."

# ---------------------------------------------------------------------------
# Phase 3 — PostgreSQL configuration
# ---------------------------------------------------------------------------
echo "=== Phase 3: PostgreSQL configuration ==="

# Determine the PostgreSQL major version directory
PG_VERSION=$(pg_config --version | grep -oP '\d+' | head -1)
PG_HBA="/etc/postgresql/${PG_VERSION}/main/pg_hba.conf"
PG_CONF="/etc/postgresql/${PG_VERSION}/main/postgresql.conf"

# Create openclaw role with CREATEDB (idempotent)
sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname='openclaw'" | grep -q 1 \
    || sudo -u postgres createuser --createdb openclaw

# Add Docker bridge subnet to pg_hba.conf (idempotent)
grep -q '172.17.0.0/16' "$PG_HBA" \
    || echo 'host all openclaw 172.17.0.0/16 trust' >> "$PG_HBA"

# Set listen_addresses to include Docker bridge (idempotent via sed)
sed -i "s/^#\?listen_addresses.*/listen_addresses = 'localhost,172.17.0.1'/" "$PG_CONF"

systemctl restart postgresql

echo "Phase 3 complete."

# ---------------------------------------------------------------------------
# Phase 4 — Directory structure
# ---------------------------------------------------------------------------
echo "=== Phase 4: Directory structure ==="

mkdir -p /opt/openclaw
mkdir -p /opt/ocs-automation
mkdir -p /data/sessions

echo "Phase 4 complete."

# ---------------------------------------------------------------------------
# Phase 5 — Application deployment
# ---------------------------------------------------------------------------
echo "=== Phase 5: Application deployment ==="

# Clone or update ocs-automation repo
if [ -d /opt/ocs-automation/.git ]; then
    git -C /opt/ocs-automation pull --ff-only || echo "git pull failed (non-fatal), continuing with existing checkout."
else
    git clone https://github.com/dimagi/ocs-automation.git /opt/ocs-automation
fi

# Copy skills to OpenClaw global skills directory
if [ -d /opt/ocs-automation/openclaw/skills ]; then
    mkdir -p /opt/openclaw/.openclaw/skills
    cp -r /opt/ocs-automation/openclaw/skills/* /opt/openclaw/.openclaw/skills/
fi

# Copy and configure Caddyfile
if [ -f /opt/ocs-automation/openclaw/Caddyfile ]; then
    cp /opt/ocs-automation/openclaw/Caddyfile /etc/caddy/Caddyfile
    sed -i "s/__DOMAIN__/${DOMAIN}/g" /etc/caddy/Caddyfile
    systemctl reload caddy || systemctl restart caddy
fi

echo "Phase 5 complete."

# ---------------------------------------------------------------------------
# Phase 6 — Secrets injection
# ---------------------------------------------------------------------------
echo "=== Phase 6: Secrets injection ==="

# Fetch region from IMDS v2
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/meta-data/placement/region)

echo "Fetching OpenClaw secrets from Secrets Manager (region: ${REGION})..."
aws secretsmanager get-secret-value \
    --secret-id ocs-automation/openclaw-env \
    --region "$REGION" \
    --query SecretString \
    --output text > /opt/openclaw/.env.tmp

chmod 600 /opt/openclaw/.env.tmp
mv /opt/openclaw/.env.tmp /opt/openclaw/.env
echo "Secrets written to /opt/openclaw/.env"

echo "Phase 6 complete."

# ---------------------------------------------------------------------------
# Phase 7 — OpenClaw installation
# ---------------------------------------------------------------------------
echo "=== Phase 7: OpenClaw installation ==="

# Install or update OpenClaw globally
npm install -g openclaw@latest

# Run openclaw setup to initialize .openclaw directory structure
OPENCLAW_HOME=/opt/openclaw openclaw setup --non-interactive 2>/dev/null || true

# Create base config if not present
OC_CONFIG="/opt/openclaw/.openclaw/openclaw.json"
if [ ! -f "$OC_CONFIG" ]; then
    mkdir -p /opt/openclaw/.openclaw
    AUTH_TOKEN=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))")
    cat > "$OC_CONFIG" << OCJSON
{
  "agents": {
    "defaults": {
      "workspace": "/opt/openclaw/.openclaw/workspace"
    }
  },
  "gateway": {
    "mode": "local",
    "auth": {
      "token": "${AUTH_TOKEN}"
    },
    "trustedProxies": ["127.0.0.1"]
  }
}
OCJSON
    chmod 600 "$OC_CONFIG"
    echo "Gateway auth token: ${AUTH_TOKEN}"
    echo "Save this token — needed for GitHub webhook configuration."
fi

# Ensure correct ownership
chown -R root:root /opt/openclaw

# Create systemd unit for openclaw-gateway (idempotent — always overwrite)
cat > /etc/systemd/system/openclaw-gateway.service << 'EOF'
[Unit]
Description=OpenClaw Gateway
After=network.target postgresql.service
Wants=postgresql.service

[Service]
Type=simple
Environment=OPENCLAW_HOME=/opt/openclaw
WorkingDirectory=/opt/openclaw
EnvironmentFile=/opt/openclaw/.env
ExecStart=/usr/bin/openclaw gateway --port 18789
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable openclaw-gateway
systemctl restart openclaw-gateway

echo "Phase 7 complete."

# ---------------------------------------------------------------------------
# Phase 8 — S3 restore (if backup exists)
# ---------------------------------------------------------------------------
echo "=== Phase 8: S3 restore (if backup exists) ==="

BUCKET=$(aws s3 ls --region "$REGION" 2>/dev/null | grep ocs-automation | head -1 | awk '{print $3}') || true

if [ -n "$BUCKET" ] && aws s3 ls "s3://${BUCKET}/backups/latest/" --region "$REGION" 2>/dev/null; then
    echo "Restoring from S3 backup (s3://${BUCKET}/backups/latest/)..."

    # Restore OpenClaw state (exclude openclaw.json to preserve auth token)
    aws s3 sync "s3://${BUCKET}/backups/latest/openclaw/" /opt/openclaw/.openclaw/ \
        --exclude "openclaw.json" --region "$REGION"

    # Restore Postgres dumps if they exist
    DUMP="/tmp/openclaw-pg-restore.sql"
    if aws s3 cp "s3://${BUCKET}/backups/latest/postgres/openclaw-pg-backup.sql" "$DUMP" --region "$REGION" 2>/dev/null; then
        sudo -u postgres psql < "$DUMP" || echo "Postgres restore encountered errors (non-fatal)."
        rm -f "$DUMP"
        echo "Postgres restored."
    fi

    systemctl restart openclaw-gateway
    echo "S3 restore complete."
else
    echo "No S3 backup found, skipping restore."
fi

echo "Phase 8 complete."

# ---------------------------------------------------------------------------
# Phase 9 — Build session container image
# ---------------------------------------------------------------------------
echo "=== Phase 9: Build session container image ==="

if [ -f /opt/ocs-automation/session/Dockerfile ]; then
    docker build -t ocs-session /opt/ocs-automation/session/
    echo "Session container image built."
else
    echo "No session Dockerfile found, skipping build."
fi

echo "Phase 9 complete."

# ---------------------------------------------------------------------------
# Phase 10 — S3 backup timer
# ---------------------------------------------------------------------------
echo "=== Phase 10: S3 backup timer ==="

# Create systemd service for backup (idempotent — always overwrite)
cat > /etc/systemd/system/openclaw-backup.service << 'EOF'
[Unit]
Description=OpenClaw S3 Backup

[Service]
Type=oneshot
ExecStart=/opt/ocs-automation/scripts/backup-to-s3.sh
EOF

# Create systemd timer (idempotent — always overwrite)
cat > /etc/systemd/system/openclaw-backup.timer << 'EOF'
[Unit]
Description=OpenClaw S3 Backup Timer

[Timer]
OnCalendar=*-*-* 00/4:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now openclaw-backup.timer

echo "Phase 10 complete."

# ---------------------------------------------------------------------------
echo "=== Bootstrap completed at $(date) ==="
