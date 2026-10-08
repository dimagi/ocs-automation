#!/bin/bash
# scripts/patch-gateway-auth.sh
# Configure gateway auth for sign-in through Caddy + oauth2-proxy:
#   - gateway.auth.mode = "trusted-proxy", identity from X-Forwarded-User (set by Caddy)
#   - OPENCLAW_GATEWAY_PASSWORD in the gateway's env file for local CLI calls that bypass
#     the proxy (`openclaw config` drops gateway.auth.password in trusted-proxy mode)
#   - gateway.auth.identityScopes grants operator.admin to GATEWAY_ADMIN_EMAILS from .env
#
# Usage: patch-gateway-auth.sh <domain>
set -euo pipefail

DOMAIN="${1:?Usage: $0 <domain>}"
CONFIG="/opt/openclaw/.openclaw/openclaw.json"
ENV_FILE="/opt/openclaw/.env"
PASSWORD_FILE="/opt/openclaw/.openclaw/gateway-password"
# Env file loaded by the gateway unit (both the bootstrap unit and OpenClaw's managed unit)
GATEWAY_ENV_FILE="/opt/openclaw/.openclaw/gateway.systemd.env"

if [ ! -f "$CONFIG" ]; then
    echo "patch-gateway-auth: $CONFIG not found, skipping."
    exit 0
fi

if grep -qE '^OPENCLAW_GATEWAY_TOKEN=' "$ENV_FILE" 2>/dev/null; then
    echo "patch-gateway-auth: remove OPENCLAW_GATEWAY_TOKEN from .env.prod; trusted-proxy auth refuses to start with a shared token." >&2
    exit 1
fi

if [ ! -s "$PASSWORD_FILE" ]; then
    (umask 077 && python3 -c "import secrets, sys; sys.stdout.write(secrets.token_urlsafe(32))" > "$PASSWORD_FILE")
    echo "patch-gateway-auth: generated gateway password"
fi
chmod 600 "$PASSWORD_FILE"
chown openclaw:openclaw "$PASSWORD_FILE"

# Trusted-proxy auth refuses to start with a shared token in the environment
touch "$GATEWAY_ENV_FILE"
sed -i '/^OPENCLAW_GATEWAY_TOKEN=/d; /^OPENCLAW_GATEWAY_PASSWORD=/d' "$GATEWAY_ENV_FILE"
echo "OPENCLAW_GATEWAY_PASSWORD=$(cat "$PASSWORD_FILE")" >> "$GATEWAY_ENV_FILE"
chmod 600 "$GATEWAY_ENV_FILE"
chown openclaw:openclaw "$GATEWAY_ENV_FILE"

ADMINS=""
if [ -f "$ENV_FILE" ]; then
    ADMINS=$(grep -E '^GATEWAY_ADMIN_EMAILS=' "$ENV_FILE" | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'" || true)
fi
if [ -z "$ADMINS" ]; then
    echo "patch-gateway-auth: GATEWAY_ADMIN_EMAILS not set in $ENV_FILE; no one gets operator.admin through sign-in."
fi

PATCH=$(jq -n \
    --arg domain "$DOMAIN" \
    --arg admins "$ADMINS" \
    '{
        gateway: {
            publicOrigin: ("https://" + $domain),
            trustedProxies: ["127.0.0.1", "::1"],
            auth: {
                mode: "trusted-proxy",
                token: null,
                trustedProxy: {
                    userHeader: "x-forwarded-user",
                    allowLoopback: true,
                    deviceAutoApprove: {enabled: true}
                },
                identityScopes: (
                    $admins | split(",") | map(gsub("(^\\s+|\\s+$)"; "")) | map(select(length > 0))
                    | map({key: ., value: ["operator.admin"]}) | from_entries
                )
            },
            remote: {token: null}
        },
        secrets: {providers: {gateway: null}}
    }')

echo "patch-gateway-auth: applying patch:"
echo "$PATCH" | jq .

echo "$PATCH" | sudo -u openclaw bash -c \
    "OPENCLAW_HOME=/opt/openclaw openclaw config patch --stdin --replace-path gateway.auth.identityScopes"

rm -f /opt/openclaw/.openclaw/gateway-token
echo "patch-gateway-auth: applied."
