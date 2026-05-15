#!/bin/bash
# scripts/patch-slack-policy.sh
# Apply hardened Slack policy via `openclaw config patch` (schema-validated write):
#   - channels.slack.groupPolicy = "allowlist"            (always)
#   - channels.slack.dmPolicy    = "pairing"              (only if currently unset)
#   - channels.slack.execApprovals.*                      (only when SLACK_APPROVERS is set in .env)
#
# SLACK_APPROVERS: comma-separated Slack user IDs (e.g. "U0123ABCD,U0456EFGH").
# When absent, execApprovals is omitted from the patch so manual config survives.
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

if jq -e '.channels.slack.dmPolicy' "$CONFIG" >/dev/null 2>&1; then
    INCLUDE_DM_POLICY=0
else
    INCLUDE_DM_POLICY=1
fi

PATCH=$(jq -n \
    --argjson includeDm "$INCLUDE_DM_POLICY" \
    --arg approvers "$APPROVERS" \
    '{
        channels: {
            slack: (
                {groupPolicy: "allowlist"}
                + (if $includeDm == 1 then {dmPolicy: "pairing"} else {} end)
                + (if $approvers != "" then {
                    execApprovals: {
                        enabled: true,
                        approvers: ($approvers | split(",") | map(gsub("(^\\s+|\\s+$)"; "")) | map(select(length > 0))),
                        target: "dm"
                    }
                } else {} end)
            )
        }
    }')

if [ -z "$APPROVERS" ]; then
    echo "patch-slack-policy: SLACK_APPROVERS not set in $ENV_FILE, leaving execApprovals untouched."
fi

echo "patch-slack-policy: applying patch:"
echo "$PATCH" | jq .

echo "$PATCH" | sudo -u openclaw bash -c "OPENCLAW_HOME=/opt/openclaw openclaw config patch --stdin"

echo "patch-slack-policy: applied."
