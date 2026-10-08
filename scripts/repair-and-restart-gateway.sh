#!/bin/bash
# scripts/repair-and-restart-gateway.sh
# Stop the gateway, run Doctor repairs, apply env/config patches, then restart and wait
# until it reports ready. Doctor cannot take maintenance ownership while the gateway runs.
#
# Usage: repair-and-restart-gateway.sh <domain>
set -euo pipefail

DOMAIN="${1:?Usage: $0 <domain>}"
SCRIPTS="$(dirname "$(readlink -f "$0")")"
UNIT="openclaw-gateway"

# Whatever fails below, never leave the gateway stopped
trap 'openclaw-user systemctl --user start "$UNIT" || true' EXIT

echo ">>> Stopping gateway..."
openclaw-user systemctl --user stop "$UNIT"

echo ">>> Running openclaw doctor --fix..."
openclaw-user openclaw doctor --fix || echo "doctor --fix reported problems; continuing"

echo ">>> Syncing gateway env..."
"$SCRIPTS/sync-gateway-env.sh"

echo ">>> Patching Slack channel policy..."
"$SCRIPTS/patch-slack-policy.sh"

echo ">>> Patching gateway auth..."
"$SCRIPTS/patch-gateway-auth.sh" "$DOMAIN"

echo ">>> Starting gateway..."
SINCE=$(date +%s)
openclaw-user systemctl --user reset-failed "$UNIT" 2>/dev/null || true
# Doctor may have started the service itself, so restart rather than start
openclaw-user systemctl --user restart "$UNIT"

for _ in $(seq 1 90); do
    sleep 2
    LOG=$(journalctl _SYSTEMD_USER_UNIT="$UNIT.service" --since "@$SINCE" -o cat)
    if grep -q "failed to start" <<< "$LOG"; then
        grep "failed to start" <<< "$LOG" | tail -1 >&2
        exit 1
    fi
    if grep -q "\[gateway\] ready" <<< "$LOG"; then
        echo "Gateway ready."
        sleep 5
        journalctl _SYSTEMD_USER_UNIT="$UNIT.service" --since "@$SINCE" -o cat | grep -iE "\[slack\].*(connected|suppressed)" | tail -1 || true
        exit 0
    fi
done

echo "Gateway did not report ready within 180s" >&2
exit 1
