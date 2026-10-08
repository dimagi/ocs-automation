#!/bin/bash
# scripts/sync-gateway-env.sh
# Refresh the gateway's env file from /opt/openclaw/.env (pulled from Secrets Manager).
#
# OpenClaw's managed gateway unit loads gateway.systemd.env, a copy of .env taken when the
# service was installed, not .env itself. Without this, rotated secrets never reach the gateway.
# Only keys already in gateway.systemd.env are updated, so the set of variables the gateway
# sees stays the one OpenClaw chose; OPENCLAW_GATEWAY_TOKEN is always removed.
set -euo pipefail

ENV_FILE="/opt/openclaw/.env"
GATEWAY_ENV_FILE="/opt/openclaw/.openclaw/gateway.systemd.env"

if [ ! -f "$GATEWAY_ENV_FILE" ]; then
    echo "sync-gateway-env: $GATEWAY_ENV_FILE not found, skipping."
    exit 0
fi

python3 - "$ENV_FILE" "$GATEWAY_ENV_FILE" <<'PY'
import os
import sys

env_path, gateway_path = sys.argv[1], sys.argv[2]


def parse(path):
    values = {}
    with open(path) as f:
        for line in f:
            key, sep, value = line.rstrip("\n").partition("=")
            if sep and key and not key.startswith("#"):
                values[key.strip()] = value
    return values


source = parse(env_path)
lines, updated, removed = [], [], []
with open(gateway_path) as f:
    for line in f:
        key, sep, value = line.rstrip("\n").partition("=")
        key = key.strip()
        if sep and key == "OPENCLAW_GATEWAY_TOKEN":
            removed.append(key)
            continue
        if sep and key in source and source[key] != value:
            line = f"{key}={source[key]}\n"
            updated.append(key)
        lines.append(line if line.endswith("\n") else line + "\n")

tmp = gateway_path + ".tmp"
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    f.writelines(lines)
os.replace(tmp, gateway_path)
print(f"sync-gateway-env: updated {updated or 'nothing'}, removed {removed or 'nothing'}")
PY

chown openclaw:openclaw "$GATEWAY_ENV_FILE"
chmod 600 "$GATEWAY_ENV_FILE"
