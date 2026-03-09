# Security Hardening & Code Quality Fixes — Design

**Date:** 2026-03-09
**Project:** ocs-automation
**Goal:** Address all findings from the 2026-03-09 code review

---

## Overview

Post-review hardening pass covering two critical security issues, three major operational risks, and a set of quality improvements across the Pulumi Python layer and operational shell scripts.

---

## Changes by Area

### 1. Pulumi Python (`infra/`)

**`infra/config.py`**
- Add `PROJECT_NAME = "ocs-automation"` constant to eliminate magic strings scattered across IAM ARNs, S3 names, and secret IDs.

**`infra/s3.py`** (new)
- Create the `ocs-automation-artifacts` S3 bucket that the IAM policy already references.
- Enable versioning. Export bucket name and ARN.

**`infra/iam.py`**
- Replace the hardcoded S3 bucket name with a reference to the Pulumi output from `infra/s3.py`.
- Scope the Secrets Manager ARN to the actual AWS region and account ID (use `pulumi_aws.get_caller_identity()` and `aws_cfg.get("region")`).

**`infra/ec2.py`**
- Fix `open("scripts/bootstrap.sh")` → use `pathlib.Path(__file__).parent.parent / "scripts/bootstrap.sh"`.
- Define a `InstanceResources` TypedDict and use it as the return type instead of bare `dict`.
- Pass the `$DOMAIN` stack config value into `user_data` via a rendered template (simple string replace).

**`infra/secrets.py`**
- Add return type annotation (`-> dict[str, aws.secretsmanager.Secret]`).

**`infra/security_group.py`**
- Add return type annotation (already has one, verify it's correct).

**`__main__.py`**
- Import and call `create_bucket()` from `infra/s3.py`.
- Pass bucket output into `create_instance_profile()`.
- Export `artifacts_bucket_name`.

**`pyproject.toml`**
- Remove unused `python-dotenv` dependency.

---

### 2. Docker Socket Security (`openclaw/docker-compose.yml`)

Add a `socket-proxy` sidecar service using `ghcr.io/tecnativa/docker-socket-proxy:latest`.

- Configure it with environment variables to allowlist only the Docker API calls OpenClaw needs:
  - `CONTAINERS=1` (list/inspect containers)
  - `POST=1` (create/start/stop containers)
  - Disable everything else (`IMAGES=0`, `NETWORKS=0`, `VOLUMES=0`, etc.)
- Remove `/var/run/docker.sock` mount from the `openclaw` service.
- Add `DOCKER_HOST=tcp://socket-proxy:2375` to the `openclaw` environment.
- The `socket-proxy` service gets the raw socket mount instead.
- Add a comment explaining the security trade-off (OpenClaw as root + Docker = host access).

---

### 3. Bootstrap Script (`scripts/bootstrap.sh`)

**Domain configuration:**
- Require a `DOMAIN` variable injected via EC2 user-data (set from `pulumi config get domain` → passed as a rendered template in `infra/ec2.py`).
- After copying openclaw config, run: `sed -i "s/YOUR_DOMAIN/$DOMAIN/g" /data/openclaw/nginx.conf`.
- Fail fast if `$DOMAIN` is empty.

**Atomic `.env` write:**
```bash
aws secretsmanager get-secret-value ... --output text > /data/openclaw/.env.tmp
chmod 600 /data/openclaw/.env.tmp
mv /data/openclaw/.env.tmp /data/openclaw/.env
```

**Version pinning:**
- Pin `uv` to a specific version: `curl ... https://astral.sh/uv/0.6.x/install.sh | sh` (or use `--version` flag).
- Pin Node.js setup to `setup_24.x` (already pinned to major; add a comment to verify hash on bumps).
- Add a comment noting these should be audited on each version bump.

**Phase banners:**
- Add `# === Phase N: <name> ===` comments to separate: OS setup, Docker install, tool install, EBS mount, app deploy, secrets, service start.

---

### 4. Session Manager (`openclaw/skills/ocs/session-manager.sh`)

**TASK_ID validation:**
```bash
if [[ ! "$TASK_ID" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "ERROR: invalid TASK_ID '$TASK_ID'" >&2
    exit 1
fi
```
Add immediately after variable assignment, before any path construction.

**Atomic lock with stale detection:**
- Replace TOCTOU check-then-write with `flock`:
  ```bash
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
      echo "ERROR: session already running" >&2; exit 1
  fi
  ```
- Add stale lock detection: if lock file exists and is older than 90 minutes, remove it before attempting lock.

**Rename PROMPT → TASK_PROMPT** throughout for consistency.

**Random Postgres password:**
- Generate `POSTGRES_PASSWORD=$(openssl rand -hex 16)` and export it for the compose session.

**TASK_PROMPT as file:**
- Write `$TASK_PROMPT` to `$SESSION_DIR/task-prompt.txt` and mount it into the container instead of passing as an env var (reduces `docker inspect` exposure).

**Dead ACTION parameter:**
- Pass `ACTION` as a Docker label on the session container for observability, or document it as reserved for future routing.

**Fix repeated compose invocation:**
- Extract `run_compose() { COMPOSE_PROJECT_NAME="session-${TASK_ID}" docker compose -f "$COMPOSE_FILE" "$@"; }` helper.

---

### 5. Session Entrypoint (`session/entrypoint.sh`)

**Deduplicate clone-or-pull:**
```bash
clone_or_update() {
    local url="$1" dir="$2"
    if [ ! -d "$dir/.git" ]; then
        git clone --depth=1 "$url" "$dir"
    else
        git -C "$dir" pull --ff-only
    fi
}
clone_or_update "$REPO_URL" /workspace/app
clone_or_update "$DOCS_REPO_URL" /workspace/docs
```

**Separate acpx stderr:**
```bash
acpx run \
    --agent claude-code \
    --workspace /workspace/app \
    --prompt-file /workspace/task-prompt.txt \
    --output-format json \
    > /workspace/output.json 2>/workspace/acpx-stderr.log
```

**TASK_PROMPT from file:**
- Read from `/workspace/task-prompt.txt` (mounted by session-manager) instead of env var.

---

## What Is Not Changing

- The overall single-session-at-a-time concurrency model (adequate for a t3.large)
- The Pulumi module structure (already clean)
- The `make_name()` naming convention
- The SSM-only access model (no SSH)
- The OpenClaw image itself (third-party, unchanged)
- The `skill.json` trigger definitions

---

## Sequencing

Changes are independent enough to implement in parallel across the five areas, with one ordering constraint: `infra/s3.py` must be created before `infra/iam.py` is updated to reference it.
