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

# Allow openclaw role from localhost via TCP (for session-manager running as openclaw)
grep -q '127.0.0.1/32.*openclaw' "$PG_HBA" \
    || echo 'host all openclaw 127.0.0.1/32 trust' >> "$PG_HBA"

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

# Create openclaw system user (idempotent)
id -u openclaw &>/dev/null || useradd --system --create-home --home-dir /opt/openclaw --shell /usr/sbin/nologin openclaw

# Gateway user needs Docker socket access to launch session containers
usermod -aG docker openclaw

# The gateway runs as a systemd user service; lingering starts the openclaw
# user manager at boot without a login session.
loginctl enable-linger openclaw

# Helper for running commands against the openclaw user manager from root, e.g.
#   openclaw-user systemctl --user restart openclaw-gateway
#   openclaw-user openclaw doctor
cat > /usr/local/bin/openclaw-user << 'EOF'
#!/bin/sh
set -eu
PASSWORD_FILE=/opt/openclaw/.openclaw/gateway-password
GATEWAY_PASSWORD=""
[ -r "$PASSWORD_FILE" ] && GATEWAY_PASSWORD=$(cat "$PASSWORD_FILE")
exec sudo -u openclaw env \
    XDG_RUNTIME_DIR="/run/user/$(id -u openclaw)" \
    OPENCLAW_HOME=/opt/openclaw \
    OPENCLAW_GATEWAY_PASSWORD="$GATEWAY_PASSWORD" \
    "$@"
EOF
chmod +x /usr/local/bin/openclaw-user

# Same environment for interactive logins (uv run inv ssh)
cat > /opt/openclaw/.profile << 'EOF'
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export OPENCLAW_HOME=/opt/openclaw
EOF

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

# Install Claude Code settings (marketplaces + enabled plugins) for the openclaw user
if [ -f /opt/ocs-automation/openclaw/claude-settings.json ]; then
    mkdir -p /opt/openclaw/.claude
    cp /opt/ocs-automation/openclaw/claude-settings.json /opt/openclaw/.claude/settings.json
    chown -R openclaw:openclaw /opt/openclaw/.claude
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

echo "Fetching GitHub App private key from Secrets Manager..."
aws secretsmanager get-secret-value \
    --secret-id ocs-automation/github-app-key \
    --region "$REGION" \
    --query SecretString \
    --output text > /opt/openclaw/github-app.pem.tmp

chmod 600 /opt/openclaw/github-app.pem.tmp
mv /opt/openclaw/github-app.pem.tmp /opt/openclaw/github-app.pem
echo "GitHub App private key written to /opt/openclaw/github-app.pem"

echo "Phase 6 complete."

# ---------------------------------------------------------------------------
# Phase 7 — OpenClaw installation
# ---------------------------------------------------------------------------
echo "=== Phase 7: OpenClaw installation ==="

# Install or update OpenClaw globally
npm install -g openclaw@latest

# Grant openclaw user write access to the global module so it can install extensions (acpx)
OC_MODULE_DIR=$(npm root -g)/openclaw
if [ -d "$OC_MODULE_DIR" ]; then
    chown -R openclaw:openclaw "$OC_MODULE_DIR"
fi

# Run openclaw setup to initialize .openclaw directory structure
OPENCLAW_HOME=/opt/openclaw openclaw setup --non-interactive 2>/dev/null || true

# Install the official plugins (idempotent — no-op if already installed)
OPENCLAW_HOME=/opt/openclaw openclaw plugins install @openclaw/acpx
OPENCLAW_HOME=/opt/openclaw openclaw plugins install @openclaw/slack

# Create base config if not present.
# Note: doctor --fix (run in deploy.sh) populates plugins.entries for slack,
# memory-core, anthropic, openai, codex etc. — keep this seed minimal.
OC_CONFIG="/opt/openclaw/.openclaw/openclaw.json"
if [ ! -f "$OC_CONFIG" ]; then
    mkdir -p /opt/openclaw/.openclaw
    cat > "$OC_CONFIG" << OCJSON
{
  "acp": {
    "enabled": true,
    "dispatch": { "enabled": true },
    "backend": "acpx",
    "defaultAgent": "claude",
    "allowedAgents": ["claude"],
    "maxConcurrentSessions": 4
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "anthropic/claude-sonnet-5-5",
        "fallbacks": ["openai/gpt-6-sol"]
      },
      "models": {
        "anthropic/claude-sonnet-5-5": { "alias": "sonnet" },
        "openai/gpt-6-sol": { "alias": "GPT" }
      },
      "workspace": "/opt/openclaw/.openclaw/workspace",
      "maxConcurrent": 4,
      "subagents": { "maxConcurrent": 8 }
    },
    "list": [
      {
        "id": "claude",
        "runtime": {
          "type": "acp",
          "acp": {
            "agent": "claude",
            "backend": "acpx",
            "mode": "persistent",
            "cwd": "/workspace/app"
          }
        }
      }
    ]
  },
  "commands": {
    "native": "auto",
    "nativeSkills": "auto",
    "restart": true,
    "ownerDisplay": "raw"
  },
  "session": {
    "dmScope": "per-channel-peer"
  },
  "channels": {
    "slack": {
      "enabled": true,
      "mode": "socket",
      "webhookPath": "/slack/events",
      "userTokenReadOnly": true,
      "appToken": { "source": "env", "provider": "default", "id": "SLACK_APP_TOKEN" },
      "botToken": { "source": "env", "provider": "default", "id": "SLACK_BOT_TOKEN" },
      "dm": { "enabled": true },
      "dmPolicy": "pairing",
      "groupPolicy": "allowlist",
      "streaming": {
        "mode": "progress",
        "progress": {
          "toolProgress": true,
          "commandText": "status"
        }
      },
      "channels": {}
    }
  },
  "messages": {
    "ackReactionScope": "group-mentions",
    "groupChat": { "visibleReplies": "message_tool" }
  },
  "plugins": {
    "entries": {
      "acpx": {
        "enabled": true,
        "config": {
          "permissionMode": "approve-all",
          "nonInteractivePermissions": "fail"
        }
      },
      "slack": {
        "enabled": true,
        "config": {}
      }
    }
  },
  "gateway": {
    "mode": "local",
    "bind": "loopback",
    "controlUi": {
      "allowedOrigins": ["https://${DOMAIN}"]
    },
    "trustedProxies": ["127.0.0.1"]
  }
}
OCJSON
    chmod 600 "$OC_CONFIG"
    echo "OpenClaw config written to ${OC_CONFIG}"
fi

# Create the gateway unit as a user unit under the openclaw user
# (idempotent — always overwrite)
USER_UNIT_DIR=/opt/openclaw/.config/systemd/user
mkdir -p "$USER_UNIT_DIR"
cat > "$USER_UNIT_DIR/openclaw-gateway.service" << 'EOF'
[Unit]
Description=OpenClaw Gateway
# User units cannot order against system units; Restart covers a late Postgres.

[Service]
Type=simple
Environment=OPENCLAW_HOME=/opt/openclaw
WorkingDirectory=/opt/openclaw
EnvironmentFile=/opt/openclaw/.env
EnvironmentFile=-/opt/openclaw/.openclaw/gateway.systemd.env
ExecStart=/usr/bin/openclaw gateway --port 18789
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF

# Ensure correct ownership
chown -R openclaw:openclaw /opt/openclaw

# Gateway auth: GitHub sign-in via Caddy + oauth2-proxy (trusted-proxy mode)
bash /opt/ocs-automation/scripts/setup-oauth2-proxy.sh "${DOMAIN}"
bash /opt/ocs-automation/scripts/patch-gateway-auth.sh "${DOMAIN}"

# Remove the system-scoped unit left by earlier bootstrap versions
if [ -f /etc/systemd/system/openclaw-gateway.service ]; then
    systemctl disable --now openclaw-gateway || true
    rm -f /etc/systemd/system/openclaw-gateway.service
    systemctl daemon-reload
fi

# The user manager is started by lingering — wait for it before talking to it
for _ in $(seq 1 30); do
    systemctl is-active "user@$(id -u openclaw).service" &>/dev/null && break
    sleep 1
done

openclaw-user systemctl --user daemon-reload
openclaw-user systemctl --user enable openclaw-gateway
openclaw-user systemctl --user restart openclaw-gateway

echo "Phase 7 complete."

# ---------------------------------------------------------------------------
# Phase 8 — Build session container image
# ---------------------------------------------------------------------------
echo "=== Phase 8: Build session container image ==="

if [ -f /opt/ocs-automation/session/Dockerfile ]; then
    docker build -t ocs-session /opt/ocs-automation/session/
    echo "Session container image built."
else
    echo "No session Dockerfile found, skipping build."
fi

echo "Phase 8 complete."

# ---------------------------------------------------------------------------
echo "=== Bootstrap completed at $(date) ==="
