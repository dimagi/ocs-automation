#!/bin/bash
# scripts/sync-gateway-token.sh
# Write the gateway token file that openclaw.json references via a file SecretRef.
# OPENCLAW_GATEWAY_TOKEN in .env (from Secrets Manager) is the source of truth;
# without it, keep the existing file or generate a random token.
set -euo pipefail

ENV_FILE="/opt/openclaw/.env"
TOKEN_FILE="/opt/openclaw/.openclaw/gateway-token"

TOKEN=""
if [ -f "$ENV_FILE" ]; then
    TOKEN=$(grep -E '^OPENCLAW_GATEWAY_TOKEN=' "$ENV_FILE" | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'" || true)
fi

mkdir -p "$(dirname "$TOKEN_FILE")"
umask 077
if [ -n "$TOKEN" ]; then
    printf '%s' "$TOKEN" > "$TOKEN_FILE"
    echo "sync-gateway-token: wrote token from .env"
elif [ ! -s "$TOKEN_FILE" ]; then
    python3 -c "import secrets, sys; sys.stdout.write(secrets.token_urlsafe(32))" > "$TOKEN_FILE"
    echo "sync-gateway-token: OPENCLAW_GATEWAY_TOKEN not set, generated a random token"
else
    echo "sync-gateway-token: OPENCLAW_GATEWAY_TOKEN not set, keeping existing token"
fi
chmod 600 "$TOKEN_FILE"
chown openclaw:openclaw "$TOKEN_FILE"
