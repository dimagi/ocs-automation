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

# Cleanup containers (keep workspace dir for audit)
COMPOSE_PROJECT_NAME="session-${TASK_ID}" \
    docker compose -f "$COMPOSE_FILE" down -v --remove-orphans
