# Security Hardening & Code Quality Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Address all findings from the 2026-03-09 code review — two critical security issues, three major operational risks, and code quality improvements.

**Architecture:** Changes are grouped into five independent areas: Pulumi Python (infra/), Docker socket hardening, bootstrap script, session-manager script, and session entrypoint. Implement in order — Task 1 (S3 bucket) must complete before Task 2 (IAM update) since IAM references the bucket output.

**Tech Stack:** Python 3.12, Pulumi 3.x, pulumi-aws 7.x, Bash, Docker Compose, nginx

---

### Task 1: Add PROJECT_NAME constant and create S3 bucket

**Files:**
- Modify: `infra/config.py`
- Create: `infra/s3.py`

**Step 1: Add PROJECT_NAME to config.py**

Open `infra/config.py` and add the constant after the imports:

```python
# infra/config.py
import pulumi
import pulumi_aws as aws

cfg = pulumi.Config()
aws_cfg = pulumi.Config("aws")

PROJECT_NAME = "ocs-automation"

# Stack-level settings
environment = cfg.get("environment") or "prod"
region = aws_cfg.get("region") or "ap-southeast-2"

# Instance settings
instance_type = cfg.get("instance_type") or "t3.large"


def make_name(resource: str) -> str:
    return f"{PROJECT_NAME}-{environment}-{resource}"
```

**Step 2: Create infra/s3.py**

```python
# infra/s3.py
import pulumi_aws as aws
from infra.config import make_name, PROJECT_NAME


def create_artifacts_bucket() -> aws.s3.BucketV2:
    """S3 bucket for session artifacts (logs, outputs)."""
    bucket = aws.s3.BucketV2(
        make_name("artifacts"),
        bucket=f"{PROJECT_NAME}-artifacts",
        tags={"Project": PROJECT_NAME},
    )

    aws.s3.BucketVersioningV2(
        make_name("artifacts-versioning"),
        bucket=bucket.id,
        versioning_configuration=aws.s3.BucketVersioningV2VersioningConfigurationArgs(
            status="Enabled",
        ),
    )

    aws.s3.BucketLifecycleConfigurationV2(
        make_name("artifacts-lifecycle"),
        bucket=bucket.id,
        rules=[
            aws.s3.BucketLifecycleConfigurationV2RuleArgs(
                id="expire-old-versions",
                status="Enabled",
                noncurrent_version_expiration=aws.s3.BucketLifecycleConfigurationV2RuleNoncurrentVersionExpirationArgs(
                    noncurrent_days=30,
                ),
            )
        ],
    )

    return bucket
```

**Step 3: Verify syntax**

```bash
cd /home/skelly/src/ocs-automation
python -c "import ast; ast.parse(open('infra/config.py').read()); print('config.py OK')"
python -c "import ast; ast.parse(open('infra/s3.py').read()); print('s3.py OK')"
```

Expected: both print OK.

**Step 4: Commit**

```bash
git add infra/config.py infra/s3.py
git commit -m "feat: add PROJECT_NAME constant and S3 artifacts bucket"
```

---

### Task 2: Update IAM to reference S3 bucket output and scope Secrets Manager ARN

**Files:**
- Modify: `infra/iam.py`

**Step 1: Rewrite infra/iam.py**

```python
# infra/iam.py
import json
import pulumi
import pulumi_aws as aws
from infra.config import make_name, environment, PROJECT_NAME


def create_instance_profile(artifacts_bucket_name: pulumi.Output) -> aws.iam.InstanceProfile:
    """EC2 IAM role with SSM, Secrets Manager, and S3 permissions."""

    identity = aws.get_caller_identity()
    region_output = aws.get_region()

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
        tags={"Environment": environment, "Project": PROJECT_NAME},
    )

    # SSM access for session manager (no SSH needed)
    aws.iam.RolePolicyAttachment(
        make_name("ssm-policy"),
        role=role.name,
        policy_arn="arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
    )

    # Read secrets from Secrets Manager — scoped to actual account and region
    secrets_policy_doc = pulumi.Output.all(identity.account_id, region_output.name).apply(
        lambda args: json.dumps({
            "Version": "2012-10-17",
            "Statement": [{
                "Effect": "Allow",
                "Action": ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"],
                "Resource": f"arn:aws:secretsmanager:{args[1]}:{args[0]}:secret:{PROJECT_NAME}/*",
            }],
        })
    )

    aws.iam.RolePolicy(
        make_name("secrets-policy"),
        role=role.id,
        policy=secrets_policy_doc,
    )

    # S3 for session artifacts — reference actual bucket output
    s3_policy_doc = artifacts_bucket_name.apply(
        lambda bucket_name: json.dumps({
            "Version": "2012-10-17",
            "Statement": [{
                "Effect": "Allow",
                "Action": ["s3:PutObject", "s3:GetObject", "s3:ListBucket"],
                "Resource": [
                    f"arn:aws:s3:::{bucket_name}",
                    f"arn:aws:s3:::{bucket_name}/*",
                ],
            }],
        })
    )

    aws.iam.RolePolicy(
        make_name("s3-policy"),
        role=role.id,
        policy=s3_policy_doc,
    )

    profile = aws.iam.InstanceProfile(
        make_name("instance-profile"),
        role=role.name,
    )

    return profile
```

**Step 2: Verify syntax**

```bash
python -c "import ast; ast.parse(open('infra/iam.py').read()); print('iam.py OK')"
```

**Step 3: Commit**

```bash
git add infra/iam.py
git commit -m "fix: scope IAM policies to actual bucket output and account/region ARNs"
```

---

### Task 3: Fix infra/ec2.py — pathlib, TypedDict, domain template

**Files:**
- Modify: `infra/ec2.py`

**Step 1: Rewrite infra/ec2.py**

```python
# infra/ec2.py
import pathlib
from typing import TypedDict

import pulumi
import pulumi_aws as aws
from infra.config import make_name, instance_type, PROJECT_NAME


class InstanceResources(TypedDict):
    instance: aws.ec2.Instance
    eip: aws.ec2.Eip
    data_volume: aws.ebs.Volume


def create_instance(
    security_group_id: pulumi.Output,
    instance_profile_name: pulumi.Output,
    domain: str,
) -> InstanceResources:
    """
    EC2 instance for OpenClaw.
    - Ubuntu 24.04 LTS (ap-southeast-2)
    - 100GB gp3 root + 200GB gp3 data volume
    - SSM-managed, no SSH key required
    """

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

    bootstrap_path = pathlib.Path(__file__).parent.parent / "scripts" / "bootstrap.sh"
    user_data = bootstrap_path.read_text().replace("__DOMAIN__", domain)

    instance = aws.ec2.Instance(
        make_name("instance"),
        ami=ami.id,
        instance_type=instance_type,
        iam_instance_profile=instance_profile_name,
        vpc_security_group_ids=[security_group_id],
        user_data=user_data,
        user_data_replace_on_change=False,  # Intentional: bootstrap runs once at first boot only
        root_block_device=aws.ec2.InstanceRootBlockDeviceArgs(
            volume_size=100,
            volume_type="gp3",
            delete_on_termination=True,
        ),
        tags={"Name": make_name("instance"), "Project": PROJECT_NAME},
    )

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

    eip = aws.ec2.Eip(
        make_name("eip"),
        instance=instance.id,
        tags={"Name": make_name("eip")},
    )

    return InstanceResources(instance=instance, eip=eip, data_volume=data_volume)
```

**Step 2: Verify syntax**

```bash
python -c "import ast; ast.parse(open('infra/ec2.py').read()); print('ec2.py OK')"
```

**Step 3: Commit**

```bash
git add infra/ec2.py
git commit -m "fix: use pathlib for bootstrap path, TypedDict return type, domain template"
```

---

### Task 4: Wire up S3 and domain in __main__.py; add type annotations to secrets.py

**Files:**
- Modify: `__main__.py`
- Modify: `infra/secrets.py`

**Step 1: Update __main__.py**

```python
# __main__.py
import pulumi
import pulumi_aws as aws
from infra.config import cfg
from infra.iam import create_instance_profile
from infra.security_group import create_security_group
from infra.ec2 import create_instance
from infra.secrets import create_secrets
from infra.s3 import create_artifacts_bucket

# Look up default VPC
vpc = aws.ec2.get_vpc(default=True)

# Domain (required — set with: pulumi config set domain <your-domain>)
domain = cfg.require("domain")

# S3 artifacts bucket
bucket = create_artifacts_bucket()

# IAM
profile = create_instance_profile(artifacts_bucket_name=bucket.bucket)

# Networking
sg = create_security_group(vpc_id=vpc.id)

# Secrets
secrets = create_secrets()

# EC2
resources = create_instance(
    security_group_id=sg.id,
    instance_profile_name=profile.name,
    domain=domain,
)

# Outputs
pulumi.export("instance_id", resources["instance"].id)
pulumi.export("public_ip", resources["eip"].public_ip)
pulumi.export("data_volume_id", resources["data_volume"].id)
pulumi.export("artifacts_bucket_name", bucket.bucket)
pulumi.export("openclaw_env_secret_arn", secrets["openclaw_env"].arn)
pulumi.export("github_app_key_secret_arn", secrets["github_app_key"].arn)
```

**Step 2: Add return type to infra/secrets.py**

Add the return type annotation to `create_secrets`:

```python
import pulumi_aws as aws
from infra.config import make_name, PROJECT_NAME


def create_secrets() -> dict[str, aws.secretsmanager.Secret]:
    """
    Create Secrets Manager secrets for OpenClaw.
    Values are set manually after deployment — never in code.

    To set a secret value after deploying:
        aws secretsmanager put-secret-value \\
            --secret-id ocs-automation/openclaw-env \\
            --secret-string "$(cat .env.prod)"
    """

    openclaw_env = aws.secretsmanager.Secret(
        make_name("openclaw-env"),
        name=f"{PROJECT_NAME}/openclaw-env",
        description="OpenClaw .env file: Anthropic, Slack, GitHub credentials",
        tags={"Project": PROJECT_NAME},
    )

    github_app_key = aws.secretsmanager.Secret(
        make_name("github-app-key"),
        name=f"{PROJECT_NAME}/github-app-key",
        description="GitHub App private key PEM for OCS automation",
        tags={"Project": PROJECT_NAME},
    )

    return {
        "openclaw_env": openclaw_env,
        "github_app_key": github_app_key,
    }
```

**Step 3: Remove python-dotenv from pyproject.toml**

Edit `pyproject.toml` — remove `"python-dotenv>=1.2.2",` from the dependencies list.

**Step 4: Verify syntax**

```bash
python -c "import ast; ast.parse(open('__main__.py').read()); print('__main__.py OK')"
python -c "import ast; ast.parse(open('infra/secrets.py').read()); print('secrets.py OK')"
```

**Step 5: Run pulumi preview to validate the full Pulumi graph**

```bash
uv run pulumi preview
```

Expected: preview shows new S3 bucket resource + updated IAM policy resources. No unexpected replacements on the EC2 instance (verify `user_data_replace_on_change=False` prevents instance recreation).

**Step 6: Commit**

```bash
git add __main__.py infra/secrets.py pyproject.toml uv.lock
git commit -m "feat: wire up S3 bucket, domain config, remove unused python-dotenv"
```

---

### Task 5: Add Docker socket proxy to openclaw/docker-compose.yml

**Files:**
- Modify: `openclaw/docker-compose.yml`

**Step 1: Update docker-compose.yml**

```yaml
# openclaw/docker-compose.yml
services:
  # Docker socket proxy — allowlists only the API calls OpenClaw needs.
  # SECURITY NOTE: Even with the proxy, openclaw runs as root (user: "0:0") and
  # has container management capability. This is a known trade-off: the proxy
  # limits blast radius from a webhook exploit but does not eliminate it.
  # Do not expose the socket-proxy port externally.
  socket-proxy:
    image: ghcr.io/tecnativa/docker-socket-proxy:latest
    container_name: openclaw-socket-proxy
    restart: unless-stopped
    environment:
      # Allow only what OpenClaw needs: list/inspect/create/start/stop containers
      CONTAINERS: 1
      POST: 1
      # Deny everything else
      IMAGES: 0
      NETWORKS: 0
      VOLUMES: 0
      INFO: 0
      BUILD: 0
      COMMIT: 0
      CONFIGS: 0
      DISTRIBUTION: 0
      EXEC: 0
      GRPC: 0
      NODES: 0
      PLUGINS: 0
      SECRETS: 0
      SERVICES: 0
      SESSION: 0
      SWARM: 0
      SYSTEM: 0
      TASKS: 0
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    networks:
      - proxy

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
      DOCKER_HOST: tcp://socket-proxy:2375
    volumes:
      - /data/openclaw/config:/home/node/.openclaw
      - /data/openclaw/workspace:/home/node/openclaw/workspace
      - /data/sessions:/data/sessions
    ports:
      - "3000:3000"
    user: "0:0"
    depends_on:
      - socket-proxy
    networks:
      - proxy
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://localhost:3000/health"]
      interval: 30s
      timeout: 10s
      retries: 3

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

networks:
  proxy:
    driver: bridge
```

**Step 2: Verify docker-compose syntax**

```bash
docker compose -f openclaw/docker-compose.yml config --quiet && echo "compose OK"
```

Expected: prints "compose OK" with no errors.

**Step 3: Commit**

```bash
git add openclaw/docker-compose.yml
git commit -m "fix: add docker-socket-proxy sidecar to limit Docker API exposure"
```

---

### Task 6: Harden scripts/bootstrap.sh

**Files:**
- Modify: `scripts/bootstrap.sh`

**Step 1: Rewrite bootstrap.sh**

```bash
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
```

**Step 2: Verify shell syntax**

```bash
bash -n scripts/bootstrap.sh && echo "bootstrap.sh syntax OK"
```

Expected: prints "bootstrap.sh syntax OK".

**Step 3: Commit**

```bash
git add scripts/bootstrap.sh
git commit -m "fix: bootstrap domain substitution, atomic .env write, chmod 600, phase banners, version pinning"
```

---

### Task 7: Harden openclaw/skills/ocs/session-manager.sh

**Files:**
- Modify: `openclaw/skills/ocs/session-manager.sh`

**Step 1: Rewrite session-manager.sh**

```bash
#!/bin/bash
# openclaw/skills/ocs/session-manager.sh
# Called by OpenClaw skill to launch a Claude Code session.
# Args: <action> <task_id> <prompt>
set -euo pipefail

ACTION="${1:-}"
TASK_ID="${2:-$(date +%s%N | md5sum | head -c12)}"
TASK_PROMPT="${3:-}"
LOCK_FILE="/data/sessions/.lock"
LOCK_FD=9
SESSION_DIR="/data/sessions/session-${TASK_ID}"
COMPOSE_FILE="/opt/ocs-automation/session/docker-compose.yml"
LOCK_TIMEOUT_MINUTES=90

# --- Input validation ---
if [[ ! "$TASK_ID" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "ERROR: invalid TASK_ID '$TASK_ID' — must match [a-zA-Z0-9_-]+" >&2
    exit 1
fi

# --- Stale lock detection ---
if [ -f "$LOCK_FILE" ]; then
    lock_age_minutes=$(( ( $(date +%s) - $(stat -c %Y "$LOCK_FILE") ) / 60 ))
    if [ "$lock_age_minutes" -ge "$LOCK_TIMEOUT_MINUTES" ]; then
        echo "[session-manager] Stale lock detected (${lock_age_minutes}m old) — removing" >&2
        rm -f "$LOCK_FILE"
    fi
fi

# --- Atomic lock via flock ---
eval "exec ${LOCK_FD}>'${LOCK_FILE}'"
if ! flock -n $LOCK_FD; then
    RUNNING=$(cat "$LOCK_FILE" 2>/dev/null || echo "unknown")
    echo "ERROR: Session '$RUNNING' already running. Task '$TASK_ID' rejected." >&2
    exit 1
fi
echo "$TASK_ID" > "$LOCK_FILE"
trap 'flock -u '"$LOCK_FD"'; rm -f "$LOCK_FILE"' EXIT

# --- Session workspace setup ---
mkdir -p "$SESSION_DIR"/{postgres,redis}

# Write TASK_PROMPT to a file to avoid env var exposure in docker inspect
printf '%s' "$TASK_PROMPT" > "$SESSION_DIR/task-prompt.txt"
chmod 600 "$SESSION_DIR/task-prompt.txt"

# --- Load OpenClaw .env for API keys ---
set -a
# shellcheck source=/dev/null
source /data/openclaw/.env
set +a

# --- Generate random Postgres password for this session ---
POSTGRES_PASSWORD=$(openssl rand -hex 16)

export TASK_ID
export POSTGRES_PASSWORD

echo "[session-manager] Starting session $TASK_ID (action: $ACTION)"

# --- Compose helper ---
run_compose() {
    COMPOSE_PROJECT_NAME="session-${TASK_ID}" \
        docker compose -f "$COMPOSE_FILE" "$@"
}

# --- Run the session ---
run_compose up \
    --exit-code-from claude \
    --abort-on-container-exit

# --- Capture output ---
OUTPUT=$(cat "$SESSION_DIR/output.json" 2>/dev/null || echo '{"error":"no output"}')

echo "[session-manager] Session $TASK_ID complete"
echo "$OUTPUT"

# --- Cleanup containers (keep workspace dir for audit) ---
run_compose down -v --remove-orphans
```

**Step 2: Verify shell syntax**

```bash
bash -n openclaw/skills/ocs/session-manager.sh && echo "session-manager.sh syntax OK"
```

Expected: prints "session-manager.sh syntax OK".

**Step 3: Commit**

```bash
git add openclaw/skills/ocs/session-manager.sh
git commit -m "fix: TASK_ID validation, flock-based atomic lock, stale lock detection, random PG password, TASK_PROMPT as file"
```

---

### Task 8: Harden session/entrypoint.sh and session/docker-compose.yml

**Files:**
- Modify: `session/entrypoint.sh`
- Modify: `session/docker-compose.yml`

**Step 1: Rewrite session/entrypoint.sh**

```bash
#!/bin/bash
# session/entrypoint.sh
# Runs inside Claude Code session container
set -euo pipefail

TASK_ID="${TASK_ID:-unknown}"
REPO_URL="${REPO_URL:-https://github.com/dimagi/open-chat-studio.git}"
DOCS_REPO_URL="${DOCS_REPO_URL:-https://github.com/dimagi/open-chat-studio-docs.git}"
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"

echo "[session:$TASK_ID] Starting"

# Clone repo if needed, otherwise fast-forward update
clone_or_update() {
    local url="$1"
    local dir="$2"
    if [ ! -d "$dir/.git" ]; then
        git clone --depth=1 "$url" "$dir"
    else
        git -C "$dir" pull --ff-only
    fi
}

clone_or_update "$REPO_URL" /workspace/app
clone_or_update "$DOCS_REPO_URL" /workspace/docs

cd /workspace/app

# Wait for Postgres to be ready
echo "[session:$TASK_ID] Waiting for Postgres..."
until pg_isready -h db -p 5432 -U postgres; do sleep 1; done

# Run Django migrations
uv run python manage.py migrate --noinput

# Read task prompt from mounted file
TASK_PROMPT_FILE="/workspace/task-prompt.txt"
if [ ! -f "$TASK_PROMPT_FILE" ]; then
    echo "ERROR: task-prompt.txt not found at $TASK_PROMPT_FILE" >&2
    exit 1
fi

# Run Claude Code via acpx in headless mode
# stderr goes to a separate log so output.json stays parseable
echo "[session:$TASK_ID] Launching Claude Code"
acpx run \
    --agent claude-code \
    --workspace /workspace/app \
    --prompt "$(cat "$TASK_PROMPT_FILE")" \
    --output-format json \
    > /workspace/output.json 2>/workspace/acpx-stderr.log

echo "[session:$TASK_ID] Complete"
cat /workspace/output.json
```

**Step 2: Update session/docker-compose.yml**

```yaml
# session/docker-compose.yml
# Template for per-task Claude Code sessions.
# Usage: TASK_ID=<id> POSTGRES_PASSWORD=<pass> docker compose up
services:
  claude:
    build:
      context: /opt/ocs-automation/session
      dockerfile: Dockerfile
    container_name: "session-${TASK_ID}"
    environment:
      TASK_ID: "${TASK_ID}"
      ANTHROPIC_API_KEY: "${ANTHROPIC_API_KEY}"
      DJANGO_SETTINGS_MODULE: "config.settings"
      DATABASE_URL: "postgresql://postgres:${POSTGRES_PASSWORD}@db:5432/open_chat_studio"
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
      POSTGRES_PASSWORD: "${POSTGRES_PASSWORD}"
      POSTGRES_DB: open_chat_studio
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

**Step 3: Verify syntax**

```bash
bash -n session/entrypoint.sh && echo "entrypoint.sh syntax OK"
docker compose -f session/docker-compose.yml config --quiet && echo "session compose OK"
```

Expected: both print OK.

**Step 4: Commit**

```bash
git add session/entrypoint.sh session/docker-compose.yml
git commit -m "fix: clone_or_update helper, separate acpx stderr, TASK_PROMPT from file, random Postgres password"
```

---

### Task 9: Final verification

**Step 1: Full Pulumi preview**

```bash
uv run pulumi preview 2>&1 | tail -30
```

Expected: new resources (S3 bucket + versioning + lifecycle, updated IAM policies). No unexpected EC2 instance replacement.

**Step 2: Syntax-check all shell scripts**

```bash
for f in scripts/bootstrap.sh session/entrypoint.sh openclaw/skills/ocs/session-manager.sh; do
    bash -n "$f" && echo "$f OK"
done
```

Expected: all three print OK.

**Step 3: Verify docker-compose files**

```bash
docker compose -f openclaw/docker-compose.yml config --quiet && echo "openclaw compose OK"
docker compose -f session/docker-compose.yml config --quiet && echo "session compose OK"
```

**Step 4: Python syntax check on all infra files**

```bash
for f in __main__.py infra/config.py infra/ec2.py infra/iam.py infra/s3.py infra/secrets.py infra/security_group.py; do
    python -c "import ast; ast.parse(open('$f').read()); print('$f OK')"
done
```

**Step 5: Final commit**

```bash
git add docs/plans/
git commit -m "docs: add security hardening design and implementation plan"
```
