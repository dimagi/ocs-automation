# Setup & Maintenance

## Prerequisites

- [Pulumi CLI](https://www.pulumi.com/docs/install/) + AWS credentials configured
- [uv](https://docs.astral.sh/uv/getting-started/installation/)
- [1Password CLI](https://developer.1password.com/docs/cli/get-started/) (`op`) for secret injection
- AWS account with permissions to create EC2, IAM, S3, and Secrets Manager resources

## Initial Setup

### 1. Create GitHub App

In **GitHub → Organization Settings → Developer settings → GitHub Apps**, create a new app:

- **Webhook URL**: `https://agent.example.com/webhook`
- **Webhook secret**: generate and save one:
  ```bash
  openssl rand -hex 32
  ```
- **Permissions**: read access to Issues, Pull Requests, and Actions
- **Subscribe to events**: Pull requests, Workflow runs
- **Callback URL**: leave blank (not needed — app uses private key auth, not OAuth)

After creating the app, generate and download a **private key** (PEM file).

To find your **Installation ID**: install the app on your org/repo, then go to
**Org Settings → Installed GitHub Apps → Configure**. The ID is in the URL:
`https://github.com/organizations/<org>/settings/installations/12345678`

### 2. Create Slack App

In [api.slack.com](https://api.slack.com/apps), create a new app and enable **Socket Mode**.

Collect:
- **App-level token** (`xapp-...`) — from Socket Mode settings
- **Bot token** (`xoxb-...`) — from OAuth & Permissions after installing to your workspace

### 3. Create `.env.prod`

Copy `openclaw/.env.example` and fill in all values:

```bash
cp openclaw/.env.example .env.prod
```

```bash
# Anthropic
ANTHROPIC_API_KEY=sk-ant-...

# Slack App (Socket Mode)
SLACK_APP_TOKEN=xapp-...
SLACK_BOT_TOKEN=xoxb-...

# GitHub App
GITHUB_APP_ID=123456
GITHUB_APP_INSTALLATION_ID=789012        # from the URL after installing the app
GITHUB_APP_PRIVATE_KEY_PATH=/opt/openclaw/github-app.pem
GITHUB_WEBHOOK_SECRET=<from step 1>

# OpenClaw gateway
OPENCLAW_GATEWAY_TOKEN=<generate: openssl rand -hex 32>
OPENCLAW_GATEWAY_BIND=lan

# OpenClaw workspace
OPENCLAW_WORKSPACE=/opt/openclaw
SESSION_MANAGER_SCRIPT=/opt/openclaw/skills/ocs/session-manager.sh
```

### 4. Create the Pulumi state bucket

Pulumi stores state in S3 (no Pulumi Cloud account needed). Create this bucket once:

```bash
aws s3 mb s3://ocs-automation-pulumi-state --region us-east-1
aws s3api put-bucket-versioning \
    --bucket ocs-automation-pulumi-state \
    --versioning-configuration Status=Enabled
```

### 5. Store the Pulumi passphrase in 1Password

Pulumi uses a passphrase to encrypt secrets in state. Generate one and store it:

```bash
op item create \
    --category=password \
    --title="ocs-automation pulumi" \
    --vault=Private \
    password=$(openssl rand -base64 32)
```

Then update `.pulumi.env` if your vault or item name differs from the defaults.

### 6. Install dependencies

```bash
uv sync
```

### 7. Configure Pulumi

```bash
op run --env-file=.pulumi.env -- pulumi stack init prod
op run --env-file=.pulumi.env -- pulumi config set domain agent.example.com
op run --env-file=.pulumi.env -- pulumi config set aws:region us-east-1
```

> **Important:** Set `domain` before running `pulumi up`. The domain is baked into the EC2
> bootstrap script at deploy time — if it's missing, bootstrap will fail and nothing will be
> installed on the instance. Bootstrap is idempotent, so a full rebuild is just `pulumi destroy && pulumi up`.

All subsequent Pulumi commands use the same `op run --env-file=.pulumi.env --` prefix — this injects `PULUMI_CONFIG_PASSPHRASE` from 1Password automatically. The S3 backend URL is already set in `Pulumi.yaml`.

### 8. Deploy infrastructure

Run `pulumi up` once to create all resources. The EC2 instance won't fully bootstrap yet — secrets and DNS must be in place first (steps 9 and 10):

```bash
op run --env-file=.pulumi.env -- pulumi up
```

Note the outputs:

```bash
op run --env-file=.pulumi.env -- pulumi stack output
# instance_id, public_ip, etc.
```

### 9. Set secrets in AWS

Bootstrap fetches these during first boot — they must exist before the instance can complete setup:

```bash
# OpenClaw .env file
aws secretsmanager put-secret-value \
    --secret-id ocs-automation/openclaw-env \
    --secret-string "$(cat .env.prod)" \
    --region us-east-1

# GitHub App private key (PEM)
aws secretsmanager put-secret-value \
    --secret-id ocs-automation/github-app-key \
    --secret-string "$(cat github-app.pem)" \
    --region us-east-1
```

### 10. Point DNS and wait for bootstrap

Point your DNS A record for `agent.example.com` at the `public_ip` output. Bootstrap must be able to reach Let's Encrypt to get a TLS certificate — **DNS must be live before bootstrap runs Caddy**.

Bootstrap runs automatically on first boot and takes ~5 minutes. Watch progress via:

```bash
aws ssm start-session --target <instance-id> --region us-east-1
sudo tail -f /var/log/bootstrap.log
```

Bootstrap installs OpenClaw, PostgreSQL, Caddy, and Docker as systemd services. Caddy handles TLS automatically via Let's Encrypt.

## Updating Config / Skills

After the initial deploy, use the deploy script to push changes to a running instance:

```bash
./scripts/deploy.sh <instance-id>
```

This syncs `openclaw/`, `session/`, and `scripts/` to S3, then applies the changes via SSM Run Command.

## Monitoring

SSH into the instance via SSM:

```bash
aws ssm start-session --target <instance-id> --region <region>
```

**Service status:**
```bash
systemctl status openclaw-gateway postgresql caddy
```

**Gateway logs (live):**
```bash
journalctl -u openclaw-gateway -f
```

**Health check:**
```bash
openclaw doctor
```

**Session containers** (ephemeral, spun up per task):
```bash
docker ps --filter name=session
```

## Administration (CLI)

Use `openclaw` CLI to administer the running gateway:

```bash
# List pending pairing requests
openclaw pairing list

# Approve a pairing request
openclaw pairing approve slack <code>

# Check config
openclaw config get

# Run health/diagnostics
openclaw doctor
```

## Backup & Restore

Backups run automatically every 4 hours via systemd timer. Manual operations:

```bash
# Trigger a backup now
uv run inv backup

# Restore from latest S3 backup
uv run inv restore

# On the instance directly:
/opt/ocs-automation/scripts/backup-to-s3.sh
/opt/ocs-automation/scripts/restore-from-s3.sh
```
