#!/bin/bash
set -euo pipefail

BUCKET="${BACKUP_BUCKET:-ocs-automation-prod-artifacts}"
PREFIX="${1:-backups/latest}"

echo "Restoring from s3://${BUCKET}/${PREFIX}/"

# Restore OpenClaw state (exclude openclaw.json to preserve auth token)
aws s3 sync "s3://${BUCKET}/${PREFIX}/openclaw/" /opt/openclaw/.openclaw/ \
    --exclude "openclaw.json"

# Restore Postgres (if dump exists)
DUMP="/tmp/openclaw-pg-restore.sql"
if aws s3 cp "s3://${BUCKET}/${PREFIX}/postgres/openclaw-pg-backup.sql" "$DUMP" 2>/dev/null; then
    sudo -u postgres psql < "$DUMP"
    rm "$DUMP"
    echo "Postgres restored."
fi

# Restart services
systemctl restart openclaw-gateway

echo "Restore complete."
