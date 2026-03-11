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
