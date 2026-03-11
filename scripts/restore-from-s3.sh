#!/bin/bash
set -euo pipefail

BUCKET="${BACKUP_BUCKET:-$(aws s3 ls | grep ocs-automation | head -1 | awk '{print $3}')}"
PREFIX="${1:-backups/latest}"

echo "Restoring from s3://${BUCKET}/${PREFIX}/"

# Restore OpenClaw config and memory (preserve .env)
aws s3 sync "s3://${BUCKET}/${PREFIX}/openclaw/config/" /opt/openclaw/config/
aws s3 sync "s3://${BUCKET}/${PREFIX}/openclaw/memory/" /opt/openclaw/memory/
aws s3 sync "s3://${BUCKET}/${PREFIX}/openclaw/skills/" /opt/openclaw/skills/

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
