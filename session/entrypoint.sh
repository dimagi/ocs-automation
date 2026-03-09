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
