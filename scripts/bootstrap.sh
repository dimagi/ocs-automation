#!/bin/bash
# scripts/bootstrap.sh
# EC2 first-boot setup for OpenClaw automation instance.
# Template variables replaced by infra/ec2.py before embedding as user-data:
#   __DOMAIN__  → the public hostname for nginx TLS (e.g. openclaw.example.com)
set -euo pipefail
exec > /var/log/bootstrap.log 2>&1

DOMAIN="__DOMAIN__"

if [ -z "$DOMAIN" ] || [ "$DOMAIN" = "__DOMAIN__" ]; then
    echo "ERROR: DOMAIN is not set. Ensure pulumi config set domain <your-domain> before deploying." >&2
    exit 1
fi

echo "=== Phase 1: OS package setup ==="
apt-get update -y
apt-get install -y \
    ca-certificates curl gnupg lsb-release \
    git unzip jq awscli \
    nginx certbot python3-certbot-nginx

echo "=== Phase 2: Docker installation ==="
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
    gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list

apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

systemctl enable docker
systemctl start docker

echo "=== Phase 3: Tool installation ==="
# Node.js v24 — pinned to major version. Verify installer hash on version bumps.
curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
apt-get install -y nodejs

# acpx (headless ACP client)
npm install -g acpx

# uv (Python package manager) — pin to specific version for reproducibility
# Check https://github.com/astral-sh/uv/releases for latest stable
UV_VERSION="0.6.6"
curl -LsSf "https://astral.sh/uv/${UV_VERSION}/install.sh" | sh

# Claude Code CLI
npm install -g @anthropic-ai/claude-code

echo "=== Phase 4: EBS data volume setup ==="
DATA_DEVICE=""
for dev in /dev/nvme1n1 /dev/xvdf /dev/sdf; do
    if [ -b "$dev" ]; then
        DATA_DEVICE="$dev"
        break
    fi
done

if [ -n "$DATA_DEVICE" ]; then
    if ! blkid "$DATA_DEVICE" 2>/dev/null | grep -q ext4; then
        mkfs.ext4 "$DATA_DEVICE"
    fi
    mkdir -p /data
    echo "$DATA_DEVICE /data ext4 defaults,nofail 0 2" >> /etc/fstab
    mount -a
fi

mkdir -p /data/openclaw/config
mkdir -p /data/openclaw/workspace
mkdir -p /data/sessions
mkdir -p /data/artifacts
chmod 755 /data

echo "=== Phase 5: Application deployment ==="
if [ ! -d /opt/ocs-automation/.git ]; then
    git clone https://github.com/dimagi/ocs-automation.git /opt/ocs-automation
fi

# Copy OpenClaw config and skills to data volume
cp -r /opt/ocs-automation/openclaw/. /data/openclaw/

# Substitute domain into nginx config
sed -i "s/YOUR_DOMAIN/${DOMAIN}/g" /data/openclaw/nginx.conf
echo "Domain configured: $DOMAIN"

echo "=== Phase 6: Secrets injection ==="
# IMDSv2 — token TTL is 6 hours (21600 seconds)
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/meta-data/placement/region)

echo "Fetching OpenClaw secrets from Secrets Manager (region: $REGION)..."
aws secretsmanager get-secret-value \
    --secret-id ocs-automation/openclaw-env \
    --region "$REGION" \
    --query SecretString \
    --output text > /data/openclaw/.env.tmp

chmod 600 /data/openclaw/.env.tmp
mv /data/openclaw/.env.tmp /data/openclaw/.env
echo "Secrets written to /data/openclaw/.env"

echo "=== Phase 7: Start OpenClaw ==="
cd /opt/ocs-automation/openclaw
docker compose up -d

echo "=== OpenClaw Bootstrap Complete ==="
