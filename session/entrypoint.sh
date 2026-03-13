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

# Wait for Postgres to be ready (extract host/port from DATABASE_URL)
if [ -z "${DATABASE_URL:-}" ]; then
    echo "ERROR: DATABASE_URL is not set" >&2
    exit 1
fi
DB_HOST=$(python3 -c "import os; from urllib.parse import urlparse; print(urlparse(os.environ['DATABASE_URL']).hostname)")
DB_PORT=$(python3 -c "import os; from urllib.parse import urlparse; print(urlparse(os.environ['DATABASE_URL']).port or 5432)")
echo "[session:$TASK_ID] Waiting for Postgres at ${DB_HOST}:${DB_PORT}..."
until pg_isready -h "$DB_HOST" -p "$DB_PORT"; do sleep 1; done

# Run Django migrations
uv run python manage.py migrate --noinput

# Read task prompt from mounted file (written by session-manager.sh)
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
