#!/bin/bash
# scripts/patch-slack-policy.sh
# Idempotently harden Slack channel policy in /opt/openclaw/.openclaw/openclaw.json:
#   - channels.slack.groupPolicy = "allowlist"
#   - channels.slack.dmPolicy    = "pairing"   (only if currently unset)
#   - channels.slack.execApprovals.* set when SLACK_APPROVERS is present in .env
#
# SLACK_APPROVERS: comma-separated Slack user IDs (e.g. "U0123ABCD,U0456EFGH").
# When absent, execApprovals is left untouched so manual config survives.
set -euo pipefail

CONFIG="/opt/openclaw/.openclaw/openclaw.json"
ENV_FILE="/opt/openclaw/.env"

if [ ! -f "$CONFIG" ]; then
    echo "patch-slack-policy: $CONFIG not found, skipping."
    exit 0
fi

if ! jq -e '.channels.slack' "$CONFIG" >/dev/null 2>&1; then
    echo "patch-slack-policy: .channels.slack not present, skipping."
    exit 0
fi

APPROVERS=""
if [ -f "$ENV_FILE" ]; then
    APPROVERS=$(grep -E '^SLACK_APPROVERS=' "$ENV_FILE" | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'" || true)
fi

# groupPolicy is overwritten unconditionally — this is the hardening contract.
# dmPolicy uses //= so a manually-set policy is preserved.
FILTER='.channels.slack.groupPolicy = "allowlist"
      | .channels.slack.dmPolicy //= "pairing"'

if [ -n "$APPROVERS" ]; then
    APPROVER_JSON=$(echo "$APPROVERS" | jq -Rc 'split(",") | map(select(length > 0))')
    FILTER="$FILTER
      | .channels.slack.execApprovals = {
          enabled: true,
          approvers: $APPROVER_JSON,
          target: \"dm\"
        }"
else
    echo "patch-slack-policy: SLACK_APPROVERS not set in $ENV_FILE, leaving execApprovals untouched."
fi

TMP=$(mktemp)
jq "$FILTER" "$CONFIG" > "$TMP"
chmod 600 "$TMP"
chown openclaw:openclaw "$TMP"
mv "$TMP" "$CONFIG"

echo "patch-slack-policy: applied."
