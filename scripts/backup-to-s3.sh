#!/bin/bash
set -euo pipefail

# Determine bucket from env or auto-detect
BUCKET="${BACKUP_BUCKET:-$(aws s3 ls | grep ocs-automation | head -1 | awk '{print $3}')}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
PREFIX="backups/${TIMESTAMP}"

echo "Backing up to s3://${BUCKET}/${PREFIX}/"

# OpenClaw config and memory
aws s3 sync /opt/openclaw/config/ "s3://${BUCKET}/${PREFIX}/openclaw/config/"
aws s3 sync /opt/openclaw/memory/ "s3://${BUCKET}/${PREFIX}/openclaw/memory/"
aws s3 sync /opt/openclaw/skills/ "s3://${BUCKET}/${PREFIX}/openclaw/skills/"

# Postgres dump (non-session databases only)
sudo -u postgres pg_dumpall --exclude-database='session_*' --format=plain \
    -f /tmp/openclaw-pg-backup.sql 2>/dev/null || true
if [ -f /tmp/openclaw-pg-backup.sql ]; then
    aws s3 cp /tmp/openclaw-pg-backup.sql "s3://${BUCKET}/${PREFIX}/postgres/"
    rm /tmp/openclaw-pg-backup.sql
fi

# Update latest pointer
aws s3 sync "s3://${BUCKET}/${PREFIX}/" "s3://${BUCKET}/backups/latest/" --delete

echo "Backup complete: s3://${BUCKET}/${PREFIX}/"
