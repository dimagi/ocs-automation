#!/bin/bash
# scripts/setup-oauth2-proxy.sh
# Install and configure oauth2-proxy, which Caddy uses (forward_auth) to require
# GitHub sign-in for the dimagi org before requests reach the gateway.
#
# Usage: setup-oauth2-proxy.sh <domain>
#
# Reads OAUTH2_PROXY_CLIENT_ID, OAUTH2_PROXY_CLIENT_SECRET and OAUTH2_PROXY_COOKIE_SECRET
# from /opt/openclaw/.env and copies only those into the service's env file.
set -euo pipefail

DOMAIN="${1:?Usage: $0 <domain>}"
VERSION="7.15.5"
SHA256="f63f94bf72c5f46ab002a0a275aa8b3cf19b4d828aed08a13978cb9a62c3a1fd"
GITHUB_ORG="dimagi"

ENV_FILE="/opt/openclaw/.env"
PROXY_ENV_FILE="/etc/oauth2-proxy/oauth2-proxy.env"
BIN="/usr/local/bin/oauth2-proxy"

# Install the pinned release
if ! "$BIN" --version 2>/dev/null | grep -q "v${VERSION}"; then
    TMP=$(mktemp -d)
    trap 'rm -rf "$TMP"' EXIT
    TARBALL="oauth2-proxy-v${VERSION}.linux-amd64.tar.gz"
    curl -fsSL -o "$TMP/$TARBALL" \
        "https://github.com/oauth2-proxy/oauth2-proxy/releases/download/v${VERSION}/${TARBALL}"
    echo "${SHA256}  $TMP/$TARBALL" | sha256sum -c -
    tar -xzf "$TMP/$TARBALL" -C "$TMP"
    install -m 755 "$TMP/oauth2-proxy-v${VERSION}.linux-amd64/oauth2-proxy" "$BIN"
    echo "setup-oauth2-proxy: installed oauth2-proxy v${VERSION}"
fi

if ! id oauth2-proxy &>/dev/null; then
    useradd --system --no-create-home --shell /usr/sbin/nologin oauth2-proxy
fi

# Copy only the oauth2-proxy secrets out of the shared .env
mkdir -p /etc/oauth2-proxy
umask 077
grep -E '^OAUTH2_PROXY_(CLIENT_ID|CLIENT_SECRET|COOKIE_SECRET)=' "$ENV_FILE" > "$PROXY_ENV_FILE.tmp"
if [ "$(wc -l < "$PROXY_ENV_FILE.tmp")" -ne 3 ]; then
    rm -f "$PROXY_ENV_FILE.tmp"
    echo "setup-oauth2-proxy: OAUTH2_PROXY_CLIENT_ID/CLIENT_SECRET/COOKIE_SECRET missing from $ENV_FILE" >&2
    exit 1
fi
mv "$PROXY_ENV_FILE.tmp" "$PROXY_ENV_FILE"
chmod 600 "$PROXY_ENV_FILE"

cat > /etc/systemd/system/oauth2-proxy.service << EOF
[Unit]
Description=oauth2-proxy (GitHub sign-in for the OpenClaw Control UI)
After=network-online.target
Wants=network-online.target

[Service]
User=oauth2-proxy
EnvironmentFile=${PROXY_ENV_FILE}
ExecStart=${BIN} \\
    --http-address=127.0.0.1:4180 \\
    --provider=github \\
    --github-org=${GITHUB_ORG} \\
    --email-domain=* \\
    --redirect-url=https://${DOMAIN}/oauth2/callback \\
    --upstream=static://202 \\
    --reverse-proxy=true \\
    --set-xauthrequest=true \\
    --skip-provider-button=true \\
    --cookie-secure=true
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable oauth2-proxy
systemctl restart oauth2-proxy
echo "setup-oauth2-proxy: oauth2-proxy running for https://${DOMAIN}"
