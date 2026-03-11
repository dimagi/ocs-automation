#!/bin/bash
# openclaw/skills/ocs/session-manager.sh
# Called by OpenClaw skill to launch a Claude Code session.
# Args: <action> <task_id> <prompt>
set -euo pipefail

# ANTHROPIC_API_KEY is inherited from the gateway container environment.
# If this check fails, verify the key is set in .env and the gateway's env_file includes it.
if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
    echo "ERROR: ANTHROPIC_API_KEY is not set — sessions cannot authenticate" >&2
    exit 1
fi

ACTION="${1:-}"
TASK_ID="${2:-$(date +%s%N | md5sum | head -c12)}"
TASK_PROMPT="${3:-}"

# --- Input validation ---
if [[ ! "$TASK_ID" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "ERROR: invalid TASK_ID '$TASK_ID' — must match [a-zA-Z0-9_-]+" >&2
    exit 1
fi

LOCK_FILE="/data/sessions/.lock"
LOCK_FD=9
SESSION_DIR="/data/sessions/session-${TASK_ID}"
COMPOSE_FILE="/opt/ocs-automation/session/docker-compose.yml"
LOCK_TIMEOUT_MINUTES=90

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
