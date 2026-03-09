# OpenClaw EC2 Automation Instance — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Stand up a self-hosted OpenClaw instance on AWS EC2 that automates open-chat-studio development tasks via Slack, GitHub, and scheduled jobs — managing isolated Claude Code sessions per task.

**Architecture:** Pulumi (Python) provisions a t3.large EC2 instance running OpenClaw in Docker. Each Claude Code task runs in its own isolated Docker Compose stack (Django + Postgres + Redis + Playwright) on the same host. Tasks are queued one at a time.

**Tech Stack:** Pulumi Python, AWS EC2/EBS/EIP/IAM/Secrets Manager/SSM, Docker, Docker Compose, OpenClaw (`ghcr.io/openclaw/openclaw`), acpx (headless ACP), Claude Code CLI, Ubuntu 24.04, uv

---

## Task 1: Project Bootstrap

**Files:**
- Create: `pyproject.toml`
- Create: `Pulumi.yaml`
- Create: `.gitignore`
- Create: `.env.example`
- Create: `infra/__init__.py`

**Step 1: Initialize uv project**

```bash
cd /home/skelly/src/ocs-automation
uv init --no-readme --python 3.12
```

**Step 2: Add Pulumi dependencies**

```bash
uv add pulumi pulumi-aws python-dotenv
uv add --dev ruff
```

**Step 3: Write Pulumi.yaml**

```yaml
# Pulumi.yaml
name: ocs-automation
runtime:
  name: python
  options:
    virtualenv: .venv
description: OpenClaw EC2 automation instance for open-chat-studio
```

**Step 4: Write pyproject.toml additions**

Edit `pyproject.toml` to add:
```toml
[tool.ruff]
line-length = 100

[tool.ruff.lint]
select = ["E", "F", "I"]
```

**Step 5: Write .gitignore**

```
.env
.env.*
!.env.example
__pycache__/
.venv/
*.egg-info/
.pulumi/
cdk.out/
*.pyc
.DS_Store
```

**Step 6: Write .env.example**

```bash
# AWS
AWS_REGION=ap-southeast-2
AWS_ACCOUNT_ID=

# Instance config
ENVIRONMENT=prod
# Access via SSM Session Manager only — no SSH, no IP whitelist needed

# Secrets (stored in AWS Secrets Manager, referenced by ARN at runtime)
# Set these via: pulumi config set --secret anthropic_api_key <value>
```

**Step 7: Create infra package**

```bash
mkdir -p infra
touch infra/__init__.py
```

**Step 8: Commit**

```bash
git init
git add .
git commit -m "feat: initialize ocs-automation project with Pulumi/Python"
```

---

## Task 2: Pulumi Config Module

**Files:**
- Create: `infra/config.py`

**Step 1: Write config.py**

```python
# infra/config.py
import pulumi
import pulumi_aws as aws

cfg = pulumi.Config()
aws_cfg = pulumi.Config("aws")

# Stack-level settings
environment = cfg.get("environment") or "prod"
region = aws_cfg.get("region") or "ap-southeast-2"

# Instance settings
instance_type = cfg.get("instance_type") or "t3.large"

# Naming helper
def make_name(resource: str) -> str:
    return f"ocs-automation-{environment}-{resource}"
```

**Step 2: Commit**

```bash
git add infra/config.py
git commit -m "feat: add Pulumi config module"
```

---

## Task 3: IAM Role & Instance Profile

**Files:**
- Create: `infra/iam.py`

**Step 1: Write iam.py**

```python
# infra/iam.py
import json
import pulumi_aws as aws
from infra.config import make_name

def create_instance_profile():
    """EC2 IAM role with SSM, Secrets Manager, and S3 permissions."""

    role = aws.iam.Role(
        make_name("role"),
        assume_role_policy=json.dumps({
            "Version": "2012-10-17",
            "Statement": [{
                "Effect": "Allow",
                "Principal": {"Service": "ec2.amazonaws.com"},
                "Action": "sts:AssumeRole",
            }],
        }),
        tags={"Environment": "prod", "Project": "ocs-automation"},
    )

    # SSM access for session manager (no SSH needed)
    aws.iam.RolePolicyAttachment(
        make_name("ssm-policy"),
        role=role.name,
        policy_arn="arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
    )

    # Read secrets from Secrets Manager
    aws.iam.RolePolicy(
        make_name("secrets-policy"),
        role=role.id,
        policy=json.dumps({
            "Version": "2012-10-17",
            "Statement": [{
                "Effect": "Allow",
                "Action": ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"],
                "Resource": "arn:aws:secretsmanager:*:*:secret:ocs-automation/*",
            }],
        }),
    )

    # S3 for session artifacts (logs, outputs)
    aws.iam.RolePolicy(
        make_name("s3-policy"),
        role=role.id,
        policy=json.dumps({
            "Version": "2012-10-17",
            "Statement": [{
                "Effect": "Allow",
                "Action": ["s3:PutObject", "s3:GetObject", "s3:ListBucket"],
                "Resource": [
                    "arn:aws:s3:::ocs-automation-artifacts",
                    "arn:aws:s3:::ocs-automation-artifacts/*",
                ],
            }],
        }),
    )

    profile = aws.iam.InstanceProfile(
        make_name("instance-profile"),
        role=role.name,
    )

    return profile
```

**Step 2: Commit**

```bash
git add infra/iam.py
git commit -m "feat: add IAM role with SSM, Secrets Manager, S3 permissions"
```

---

## Task 4: Security Group

**Files:**
- Create: `infra/security_group.py`

**Step 1: Write security_group.py**

```python
# infra/security_group.py
import pulumi_aws as aws
from infra.config import make_name

def create_security_group(vpc_id: str) -> aws.ec2.SecurityGroup:
    """
    Security group for the OpenClaw EC2 instance.
    - HTTPS (443) open for Slack/GitHub webhooks
    - No SSH — access exclusively via SSM Session Manager
    - All outbound allowed
    """
    sg = aws.ec2.SecurityGroup(
        make_name("sg"),
        vpc_id=vpc_id,
        description="OpenClaw automation instance",
        ingress=[
            # HTTPS for Slack/GitHub webhooks
            aws.ec2.SecurityGroupIngressArgs(
                protocol="tcp",
                from_port=443,
                to_port=443,
                cidr_blocks=["0.0.0.0/0"],
                description="HTTPS for webhooks",
            ),
            # No SSH rule — use SSM Session Manager instead
        ],
        egress=[
            aws.ec2.SecurityGroupEgressArgs(
                protocol="-1",
                from_port=0,
                to_port=0,
                cidr_blocks=["0.0.0.0/0"],
                description="All outbound",
            ),
        ],
        tags={"Name": make_name("sg")},
    )
    return sg
```

**Step 2: Commit**

```bash
git add infra/security_group.py
git commit -m "feat: add security group (HTTPS webhooks only, SSM for access)"
```

---

## Task 5: EC2 Instance + EBS + Elastic IP

**Files:**
- Create: `infra/ec2.py`
- Create: `scripts/bootstrap.sh` (referenced as user data)

**Step 1: Write scripts/bootstrap.sh**

This runs on first boot. It installs Docker, OpenClaw dependencies, and sets up the workspace directory structure.

```bash
#!/bin/bash
# scripts/bootstrap.sh
# EC2 first-boot setup for OpenClaw automation instance
set -euo pipefail
exec > /var/log/bootstrap.log 2>&1

echo "=== OpenClaw Bootstrap Starting ==="

# Update system
apt-get update -y
apt-get install -y \
    ca-certificates curl gnupg lsb-release \
    git unzip jq awscli \
    nginx certbot python3-certbot-nginx

# Install Docker
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
    gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list

apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

# Enable Docker
systemctl enable docker
systemctl start docker

# Install Node.js (for acpx)
curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
apt-get install -y nodejs

# Install acpx (headless ACP client)
npm install -g acpx

# Install uv (for Claude Code sessions that need Python)
curl -LsSf https://astral.sh/uv/install.sh | sh

# Install Claude Code CLI
npm install -g @anthropic-ai/claude-code

# Mount and format data EBS volume (attached as /dev/nvme1n1 or /dev/xvdf)
DATA_DEVICE=""
for dev in /dev/nvme1n1 /dev/xvdf /dev/sdf; do
    if [ -b "$dev" ]; then
        DATA_DEVICE="$dev"
        break
    fi
done

if [ -n "$DATA_DEVICE" ]; then
    if ! blkid "$DATA_DEVICE"; then
        mkfs.ext4 "$DATA_DEVICE"
    fi
    mkdir -p /data
    echo "$DATA_DEVICE /data ext4 defaults,nofail 0 2" >> /etc/fstab
    mount -a
fi

# Create directory structure
mkdir -p /data/openclaw/config
mkdir -p /data/openclaw/workspace
mkdir -p /data/sessions
mkdir -p /data/artifacts
chmod 755 /data

# Clone ocs-automation repo (for openclaw config + session compose files)
git clone https://github.com/dimagi/ocs-automation.git /opt/ocs-automation || true

# Copy OpenClaw config and skills to data volume
cp -r /opt/ocs-automation/openclaw/. /data/openclaw/

# Pull secrets from Secrets Manager and write .env
REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
aws secretsmanager get-secret-value \
    --secret-id ocs-automation/openclaw-env \
    --region "$REGION" \
    --query SecretString \
    --output text > /data/openclaw/.env

# Start OpenClaw
cd /opt/ocs-automation/openclaw
docker compose up -d

echo "=== OpenClaw Bootstrap Complete ==="
```

**Step 2: Write infra/ec2.py**

```python
# infra/ec2.py
import pulumi
import pulumi_aws as aws
from infra.config import make_name, instance_type

def create_instance(
    security_group_id: pulumi.Output,
    instance_profile_name: pulumi.Output,
) -> dict:
    """
    EC2 instance for OpenClaw.
    - Ubuntu 24.04 LTS (ap-southeast-2)
    - 100GB gp3 root + 200GB gp3 data volume
    - SSM-managed, no SSH key required
    """

    # Ubuntu 24.04 LTS AMI (ap-southeast-2) — look up dynamically
    ami = aws.ec2.get_ami(
        most_recent=True,
        owners=["099720109477"],  # Canonical
        filters=[
            aws.ec2.GetAmiFilterArgs(
                name="name",
                values=["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"],
            ),
            aws.ec2.GetAmiFilterArgs(name="virtualization-type", values=["hvm"]),
        ],
    )

    with open("scripts/bootstrap.sh") as f:
        user_data = f.read()

    instance = aws.ec2.Instance(
        make_name("instance"),
        ami=ami.id,
        instance_type=instance_type,
        iam_instance_profile=instance_profile_name,
        vpc_security_group_ids=[security_group_id],
        user_data=user_data,
        user_data_replace_on_change=False,  # don't reprovision on script changes
        root_block_device=aws.ec2.InstanceRootBlockDeviceArgs(
            volume_size=100,
            volume_type="gp3",
            delete_on_termination=True,
        ),
        tags={"Name": make_name("instance"), "Project": "ocs-automation"},
    )

    # Separate data EBS volume (persists if instance replaced)
    data_volume = aws.ebs.Volume(
        make_name("data-volume"),
        availability_zone=instance.availability_zone,
        size=200,
        type="gp3",
        tags={"Name": make_name("data-volume")},
    )

    aws.ec2.VolumeAttachment(
        make_name("data-volume-attachment"),
        instance_id=instance.id,
        volume_id=data_volume.id,
        device_name="/dev/sdf",
    )

    # Elastic IP for stable address
    eip = aws.ec2.Eip(
        make_name("eip"),
        instance=instance.id,
        tags={"Name": make_name("eip")},
    )

    return {"instance": instance, "eip": eip, "data_volume": data_volume}
```

**Step 3: Commit**

```bash
git add infra/ec2.py scripts/bootstrap.sh
git commit -m "feat: add EC2 instance (t3.large), data EBS volume, Elastic IP"
```

---

## Task 6: Secrets Manager Resources

**Files:**
- Create: `infra/secrets.py`

These resources create the Secrets Manager placeholders. Actual secret values are set out-of-band via AWS CLI or console, never in code.

**Step 1: Write infra/secrets.py**

```python
# infra/secrets.py
import pulumi_aws as aws
from infra.config import make_name

def create_secrets() -> dict:
    """
    Create Secrets Manager secrets for OpenClaw.
    Values are set manually after deployment — never in code.

    To set a secret value:
        aws secretsmanager put-secret-value \
            --secret-id ocs-automation/openclaw-env \
            --secret-string "$(cat .env.prod)"
    """

    # Single secret containing full .env file for OpenClaw
    # Format: KEY=value\nKEY2=value2 (dotenv format)
    openclaw_env = aws.secretsmanager.Secret(
        make_name("openclaw-env"),
        name="ocs-automation/openclaw-env",
        description="OpenClaw .env file: Anthropic, Slack, GitHub credentials",
        tags={"Project": "ocs-automation"},
    )

    # GitHub App private key (PEM, stored separately as it's large)
    github_app_key = aws.secretsmanager.Secret(
        make_name("github-app-key"),
        name="ocs-automation/github-app-key",
        description="GitHub App private key PEM for OCS automation",
        tags={"Project": "ocs-automation"},
    )

    return {
        "openclaw_env": openclaw_env,
        "github_app_key": github_app_key,
    }
```

**Step 2: Commit**

```bash
git add infra/secrets.py
git commit -m "feat: add Secrets Manager secret placeholders"
```

---

## Task 7: Pulumi Entry Point

**Files:**
- Create: `infra/__main__.py`

**Step 1: Write infra/__main__.py**

```python
# infra/__main__.py
import pulumi
import pulumi_aws as aws
from infra.config import make_name
from infra.iam import create_instance_profile
from infra.security_group import create_security_group
from infra.ec2 import create_instance
from infra.secrets import create_secrets

# Look up default VPC (or use specific VPC ID from config if needed)
vpc = aws.ec2.get_vpc(default=True)

# IAM
profile = create_instance_profile()

# Networking
sg = create_security_group(vpc_id=vpc.id)

# Secrets
secrets = create_secrets()

# EC2
resources = create_instance(
    security_group_id=sg.id,
    instance_profile_name=profile.name,
)

# Outputs
pulumi.export("instance_id", resources["instance"].id)
pulumi.export("public_ip", resources["eip"].public_ip)
pulumi.export("data_volume_id", resources["data_volume"].id)
pulumi.export("openclaw_env_secret_arn", secrets["openclaw_env"].arn)
pulumi.export("github_app_key_secret_arn", secrets["github_app_key"].arn)
```

**Step 2: Preview the stack**

```bash
cd /home/skelly/src/ocs-automation
pulumi preview
```

Expected: Shows plan to create EC2 instance, EBS volumes, EIP, IAM role, security group, secrets. No errors.

**Step 3: Commit**

```bash
git add infra/__main__.py
git commit -m "feat: add Pulumi entry point with all infrastructure wired up"
```

---

## Task 8: OpenClaw Docker Compose

**Files:**
- Create: `openclaw/docker-compose.yml`
- Create: `openclaw/.env.example`

**Step 1: Write openclaw/docker-compose.yml**

```yaml
# openclaw/docker-compose.yml
services:
  openclaw:
    image: ghcr.io/openclaw/openclaw:latest
    container_name: openclaw
    restart: unless-stopped
    init: true
    env_file:
      - .env
    environment:
      HOME: /home/node
      TERM: xterm-256color
      NODE_ENV: production
    volumes:
      - /data/openclaw/config:/home/node/.openclaw
      - /data/openclaw/workspace:/home/node/openclaw/workspace
      - /data/sessions:/data/sessions         # session manager needs host access
      - /var/run/docker.sock:/var/run/docker.sock  # for spawning session containers
    ports:
      - "3000:3000"
    user: "0:0"  # root needed for docker.sock access; tighten after testing
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://localhost:3000/health"]
      interval: 30s
      timeout: 10s
      retries: 3

  # Nginx reverse proxy (handles HTTPS for Slack/GitHub webhooks)
  nginx:
    image: nginx:alpine
    container_name: openclaw-nginx
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - /etc/letsencrypt:/etc/letsencrypt:ro
    depends_on:
      - openclaw
```

**Step 2: Write openclaw/.env.example**

```bash
# openclaw/.env.example
# Copy to .env and fill in values
# This file is loaded by docker-compose.yml

# Anthropic
ANTHROPIC_API_KEY=

# Slack App (Socket Mode)
SLACK_APP_TOKEN=xapp-...
SLACK_BOT_TOKEN=xoxb-...

# GitHub App
GITHUB_APP_ID=
GITHUB_APP_INSTALLATION_ID=
GITHUB_APP_PRIVATE_KEY_PATH=/home/node/.openclaw/github-app.pem

# OpenClaw workspace
OPENCLAW_WORKSPACE=/home/node/openclaw/workspace

# Session manager hook — called by OpenClaw skill to launch a Claude Code session
SESSION_MANAGER_SCRIPT=/home/node/openclaw/workspace/skills/ocs/session-manager.sh
```

**Step 3: Write openclaw/nginx.conf**

```nginx
# openclaw/nginx.conf
server {
    listen 80;
    server_name _;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name _;

    ssl_certificate /etc/letsencrypt/live/YOUR_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/YOUR_DOMAIN/privkey.pem;

    location / {
        proxy_pass http://openclaw:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
```

**Step 4: Commit**

```bash
git add openclaw/
git commit -m "feat: add OpenClaw docker-compose, nginx proxy, env template"
```

---

## Task 9: Session Container

Each Claude Code task runs in an isolated Docker Compose stack. The session manager script (called by the OpenClaw skill) creates a new session directory and starts it.

**Files:**
- Create: `session/Dockerfile`
- Create: `session/docker-compose.yml`
- Create: `session/entrypoint.sh`

**Step 1: Write session/Dockerfile**

```dockerfile
# session/Dockerfile
# Claude Code session container for open-chat-studio tasks
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    git curl unzip jq \
    python3 python3-pip python3-venv \
    chromium-browser \
    postgresql-client \
    && rm -rf /var/lib/apt/lists/*

# Node.js (for Claude Code + acpx)
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# uv (Python package manager)
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="/root/.cargo/bin:/root/.local/bin:$PATH"

# Claude Code CLI
RUN npm install -g @anthropic-ai/claude-code

# acpx (headless ACP client)
RUN npm install -g acpx

WORKDIR /workspace

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
```

**Step 2: Write session/entrypoint.sh**

```bash
#!/bin/bash
# session/entrypoint.sh
# Runs inside Claude Code session container
set -euo pipefail

TASK_ID="${TASK_ID:-unknown}"
TASK_PROMPT="${TASK_PROMPT:-}"
REPO_URL="${REPO_URL:-https://github.com/dimagi/open-chat-studio.git}"
DOCS_REPO_URL="${DOCS_REPO_URL:-https://github.com/dimagi/open-chat-studio-docs.git}"
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"

echo "[session:$TASK_ID] Starting"

# Clone or update app repo
if [ ! -d /workspace/app/.git ]; then
    git clone --depth=1 "$REPO_URL" /workspace/app
else
    git -C /workspace/app pull --ff-only
fi

# Clone or update docs repo (available at /workspace/docs for context)
if [ ! -d /workspace/docs/.git ]; then
    git clone --depth=1 "$DOCS_REPO_URL" /workspace/docs
else
    git -C /workspace/docs pull --ff-only
fi

cd /workspace/app

# Wait for Postgres to be ready
echo "[session:$TASK_ID] Waiting for Postgres..."
until pg_isready -h db -p 5432 -U postgres; do sleep 1; done

# Run Django migrations
uv run python manage.py migrate --noinput

# Run Claude Code via acpx in headless mode
echo "[session:$TASK_ID] Launching Claude Code"
acpx run \
    --agent claude-code \
    --workspace /workspace/app \
    --prompt "$TASK_PROMPT" \
    --output-format json \
    > /workspace/output.json 2>&1

echo "[session:$TASK_ID] Complete"
cat /workspace/output.json
```

**Step 3: Write session/docker-compose.yml**

This is a template — the session manager script fills in `TASK_ID`, `TASK_PROMPT`, etc.

```yaml
# session/docker-compose.yml
# Template for per-task Claude Code sessions.
# Usage: TASK_ID=<id> TASK_PROMPT="..." docker compose up
services:
  claude:
    build:
      context: /opt/ocs-automation/session
      dockerfile: Dockerfile
    container_name: "session-${TASK_ID}"
    environment:
      TASK_ID: "${TASK_ID}"
      TASK_PROMPT: "${TASK_PROMPT}"
      ANTHROPIC_API_KEY: "${ANTHROPIC_API_KEY}"
      DJANGO_SETTINGS_MODULE: "settings"
      DATABASE_URL: "postgresql://postgres:postgres@db:5432/ocs"
      DOCS_REPO_URL: "https://github.com/dimagi/open-chat-studio-docs.git"
    volumes:
      - "/data/sessions/${TASK_ID}:/workspace"
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_healthy

  db:
    image: postgres:16-alpine
    container_name: "session-${TASK_ID}-db"
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: ocs
    volumes:
      - "/data/sessions/${TASK_ID}/postgres:/var/lib/postgresql/data"
    healthcheck:
      test: ["CMD", "pg_isready", "-U", "postgres"]
      interval: 5s
      retries: 10

  redis:
    image: redis:7-alpine
    container_name: "session-${TASK_ID}-redis"
    volumes:
      - "/data/sessions/${TASK_ID}/redis:/data"
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      retries: 10
```

**Step 4: Commit**

```bash
git add session/
git commit -m "feat: add session container (Claude Code + Django + Postgres + Redis)"
```

---

## Task 10: OpenClaw OCS Skill

The OCS skill tells OpenClaw how to route incoming tasks to the session manager.

**Files:**
- Create: `openclaw/skills/ocs/skill.json`
- Create: `openclaw/skills/ocs/session-manager.sh`
- Create: `openclaw/skills/ocs/prompts/pr-review.md`
- Create: `openclaw/skills/ocs/prompts/ci-triage.md`
- Create: `openclaw/skills/ocs/prompts/work-on-issue.md`
- Create: `openclaw/skills/ocs/prompts/scheduled-typecheck.md`

**Step 1: Write skill.json**

```json
{
  "name": "ocs",
  "version": "1.0.0",
  "description": "OpenClaw skill for open-chat-studio automation",
  "triggers": [
    {
      "type": "slack-mention",
      "pattern": "work on #(\\d+)",
      "action": "work-on-issue",
      "capture": "issue_number"
    },
    {
      "type": "slack-mention",
      "pattern": "review #(\\d+)",
      "action": "review-issue",
      "capture": "issue_number"
    },
    {
      "type": "slack-command",
      "command": "/ocs",
      "action": "ad-hoc"
    },
    {
      "type": "github-webhook",
      "event": "pull_request",
      "actions": ["opened", "synchronize"],
      "action": "pr-review"
    },
    {
      "type": "github-webhook",
      "event": "workflow_run",
      "conclusion": "failure",
      "action": "ci-triage"
    },
    {
      "type": "cron",
      "schedule": "0 6 * * 1-5",
      "action": "scheduled-typecheck",
      "description": "Weekday 6am — incremental type checking progress"
    }
  ],
  "session": {
    "manager": "./session-manager.sh",
    "lock_file": "/data/sessions/.lock",
    "timeout_minutes": 60
  }
}
```

**Step 2: Write session-manager.sh**

```bash
#!/bin/bash
# openclaw/skills/ocs/session-manager.sh
# Called by OpenClaw skill to launch a Claude Code session.
# Args: <action> <task_id> <prompt>
set -euo pipefail

ACTION="${1:-}"
TASK_ID="${2:-$(date +%s)}"
PROMPT="${3:-}"
LOCK_FILE="/data/sessions/.lock"
SESSION_DIR="/data/sessions/session-${TASK_ID}"
COMPOSE_FILE="/opt/ocs-automation/session/docker-compose.yml"

# Enforce single session at a time
if [ -f "$LOCK_FILE" ]; then
    RUNNING=$(cat "$LOCK_FILE")
    echo "ERROR: Session $RUNNING already running. Task $TASK_ID queued." >&2
    exit 1
fi

echo "$TASK_ID" > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

# Create session workspace
mkdir -p "$SESSION_DIR"/{postgres,redis}

# Load OpenClaw .env for API keys
set -a
source /data/openclaw/.env
set +a

# Export session vars
export TASK_ID="$TASK_ID"
export TASK_PROMPT="$PROMPT"

echo "[session-manager] Starting session $TASK_ID (action: $ACTION)"

# Run the session
COMPOSE_PROJECT_NAME="session-${TASK_ID}" \
    docker compose -f "$COMPOSE_FILE" up \
    --exit-code-from claude \
    --abort-on-container-exit

# Capture output
OUTPUT=$(cat "$SESSION_DIR/output.json" 2>/dev/null || echo '{"error":"no output"}')

echo "[session-manager] Session $TASK_ID complete"
echo "$OUTPUT"

# Cleanup containers (keep workspace for audit)
COMPOSE_PROJECT_NAME="session-${TASK_ID}" \
    docker compose -f "$COMPOSE_FILE" down -v --remove-orphans
```

**Step 3: Write prompt templates**

```markdown
<!-- openclaw/skills/ocs/prompts/pr-review.md -->
# PR Review Task

You are reviewing PR #{{pr_number}} in the open-chat-studio repository.

Your job:
1. Read the PR diff carefully
2. Check for bugs, security issues, and code quality problems
3. Run the test suite: `uv run pytest`
4. Post a structured review comment to the PR via GitHub CLI

Use `gh pr view {{pr_number}}` to get PR details and `gh pr diff {{pr_number}}` for the diff.
Post your review with `gh pr review {{pr_number}} --comment -b "..."`.

Be concise. Focus on bugs and correctness, not style nitpicks.
```

```markdown
<!-- openclaw/skills/ocs/prompts/ci-triage.md -->
# CI Failure Triage

CI failed on {{branch}} (run ID: {{run_id}}).

Your job:
1. Fetch the failure logs: `gh run view {{run_id}} --log-failed`
2. Identify the root cause
3. If it's a flaky test, say so clearly
4. If it's a real failure, diagnose and suggest a fix
5. Post your analysis to Slack channel #ocs-ci-alerts

Be specific about the failing test/step and likely cause. Keep it under 300 words.
```

```markdown
<!-- openclaw/skills/ocs/prompts/work-on-issue.md -->
# Work On Issue #{{issue_number}}

Your job: implement the changes described in GitHub issue #{{issue_number}}.

Steps:
1. Read the issue: `gh issue view {{issue_number}}`
2. Understand the codebase context (read relevant files)
3. Write tests first (TDD)
4. Implement the changes
5. Run tests: `uv run pytest`
6. Open a draft PR when done: `gh pr create --draft --title "..." --body "..."`

Stay focused on what the issue asks for. Don't refactor unrelated code.
```

```markdown
<!-- openclaw/skills/ocs/prompts/scheduled-typecheck.md -->
# Incremental Type Checking Session

Your job: make measurable progress on adding type annotations to open-chat-studio.

Steps:
1. Run mypy to see current state: `uv run mypy apps/ --ignore-missing-imports 2>&1 | tail -20`
2. Pick one module with the most errors
3. Fix type errors in that module incrementally
4. Run mypy again to confirm improvement
5. Commit the changes with a clear message
6. Open a PR or push to an existing type-checking branch

Target: reduce error count by at least 10 errors per session.
```

**Step 4: Commit**

```bash
git add openclaw/skills/
git commit -m "feat: add OCS OpenClaw skill with session manager and task prompts"
```

---

## Task 11: Deploy Script

**Files:**
- Create: `scripts/deploy.sh`

**Step 1: Write scripts/deploy.sh**

```bash
#!/bin/bash
# scripts/deploy.sh
# Update OpenClaw config and skills on a running EC2 instance.
# Usage: ./scripts/deploy.sh <instance-id>
set -euo pipefail

INSTANCE_ID="${1:-}"
if [ -z "$INSTANCE_ID" ]; then
    echo "Usage: $0 <instance-id>"
    echo "Get instance ID: pulumi stack output instance_id"
    exit 1
fi

REGION="${AWS_REGION:-ap-southeast-2}"

echo "Deploying to instance $INSTANCE_ID..."

# Upload openclaw config and skills via SSM + S3
BUCKET="ocs-automation-artifacts"
aws s3 sync openclaw/ "s3://$BUCKET/openclaw/" --region "$REGION"
aws s3 sync session/ "s3://$BUCKET/session/" --region "$REGION"
aws s3 sync scripts/ "s3://$BUCKET/scripts/" --region "$REGION"

# Run update commands on the instance
aws ssm send-command \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --region "$REGION" \
    --parameters 'commands=[
        "aws s3 sync s3://ocs-automation-artifacts/openclaw/ /data/openclaw/ --region '\"$REGION\"'",
        "aws s3 sync s3://ocs-automation-artifacts/session/ /opt/ocs-automation/session/ --region '\"$REGION\"'",
        "chmod +x /opt/ocs-automation/openclaw/skills/ocs/session-manager.sh",
        "cd /opt/ocs-automation/openclaw && docker compose pull && docker compose up -d",
        "docker build -t ocs-session /opt/ocs-automation/session/"
    ]' \
    --output text

echo "Deploy complete. Check SSM Run Command console for status."
```

**Step 2: Make executable and commit**

```bash
chmod +x scripts/deploy.sh scripts/bootstrap.sh
git add scripts/deploy.sh
git commit -m "feat: add deploy script for updating OpenClaw on running instance"
```

---

## Task 12: Initial Deployment

**Step 1: Configure Pulumi stack**

```bash
pulumi stack init prod
pulumi config set aws:region ap-southeast-2
pulumi config set ocs-automation:environment prod
```

**Step 2: Preview deployment**

```bash
pulumi preview
```

Expected: Shows creation of EC2, EBS volumes, EIP, IAM role, security groups, Secrets Manager secrets.

**Step 3: Deploy infrastructure**

```bash
pulumi up
```

Note the outputs — especially `public_ip` and `openclaw_env_secret_arn`.

**Step 4: Populate secrets**

Create a local `.env.prod` with real credentials, then:

```bash
# Populate the OpenClaw env secret
aws secretsmanager put-secret-value \
    --secret-id ocs-automation/openclaw-env \
    --secret-string "$(cat .env.prod)"

# Populate GitHub App private key
aws secretsmanager put-secret-value \
    --secret-id ocs-automation/github-app-key \
    --secret-string "$(cat github-app.pem)"
```

**Step 5: Verify instance is running**

```bash
# Connect via SSM (no SSH needed)
aws ssm start-session --target "$(pulumi stack output instance_id)"

# Check bootstrap logs
sudo tail -f /var/log/bootstrap.log

# Check OpenClaw is running
sudo docker compose -f /opt/ocs-automation/openclaw/docker-compose.yml ps
```

**Step 6: Set up DNS + TLS for webhooks**

Point a DNS record at the Elastic IP (`pulumi stack output public_ip`), then on the instance:

```bash
sudo certbot --nginx -d YOUR_DOMAIN --non-interactive --agree-tos -m YOUR_EMAIL
```

**Step 7: Configure GitHub App webhook**

In GitHub App settings, set webhook URL to `https://YOUR_DOMAIN/github/events`.

**Step 8: Verify end-to-end**

Send a test message to the OpenClaw Slack bot: `@openclaw hello`

Expected: OpenClaw responds in Slack confirming it's online.

---

## Task 13: Smoke Test Session

**Step 1: Trigger a manual ad-hoc session via Slack**

Send in the `#ocs-automation` Slack channel:
```
/ocs list the top-level Django apps in open-chat-studio
```

**Step 2: Monitor session startup**

On the EC2 instance via SSM:
```bash
watch -n 2 'docker ps --format "table {{.Names}}\t{{.Status}}"'
```

Expected: See `session-<id>`, `session-<id>-db`, `session-<id>-redis` containers start.

**Step 3: Verify output**

Expected: OpenClaw posts a Slack reply with the list of Django apps from open-chat-studio.

**Step 4: Verify cleanup**

After session completes, the containers should be removed:
```bash
ls /data/sessions/  # workspace dir remains for audit
docker ps           # session containers gone
```

---

## Notes

### Credentials You'll Need Before Task 12

- **Anthropic API key** — from console.anthropic.com
- **Slack App** — create at api.slack.com; needs `app_mentions:read`, `chat:write`, `commands` scopes; Socket Mode enabled
- **GitHub App** — create at github.com/settings/apps; needs `pull_requests:write`, `issues:write`, `actions:read`, `contents:read` on dimagi/open-chat-studio; note App ID + Installation ID

### Accessing the Instance

```bash
# Connect (no SSH key needed)
aws ssm start-session --target $(pulumi stack output instance_id)

# View OpenClaw logs
docker logs -f openclaw
```

### Updating OpenClaw Config

```bash
./scripts/deploy.sh $(pulumi stack output instance_id)
```
