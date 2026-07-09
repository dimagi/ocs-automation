#!/bin/bash
set -euo pipefail

# Determine bucket from env or use default
BUCKET="${BACKUP_BUCKET:-ocs-automation-prod-artifacts}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
PREFIX="snapshots/${TIMESTAMP}"

echo "Backing up to s3://${BUCKET}/${PREFIX}/"

# OpenClaw state (config, memory, agents) — exclude logs, identity, the
# reinstallable npm tooling, and session transcripts (large + regenerable;
# session_* DBs are likewise excluded from the Postgres dump below).
aws s3 sync /opt/openclaw/.openclaw/ "s3://${BUCKET}/${PREFIX}/openclaw/" \
    --exclude "logs/*" --exclude "identity/*" \
    --exclude "npm/*" --exclude "agents/*/sessions/*"

# Postgres dump (non-session databases only)
sudo -u postgres pg_dumpall --exclude-database='session_*' --format=plain \
    -f /tmp/openclaw-pg-backup.sql 2>/dev/null || true
if [ -f /tmp/openclaw-pg-backup.sql ]; then
    aws s3 cp /tmp/openclaw-pg-backup.sql "s3://${BUCKET}/${PREFIX}/postgres/"
    rm /tmp/openclaw-pg-backup.sql
fi

# Update latest pointer (the DR restore source read by bootstrap on launch).
# latest/ lives under backups/, outside the snapshots/ expiry rule, so it is
# never expired regardless of backup cadence.
aws s3 sync "s3://${BUCKET}/${PREFIX}/" "s3://${BUCKET}/backups/latest/" --delete

echo "Backup complete: s3://${BUCKET}/${PREFIX}/"
