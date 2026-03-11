# openclaw/Dockerfile
# Extends the upstream openclaw image with Docker CLI so session-manager.sh
# can run docker compose inside the container via the socket proxy.
FROM ghcr.io/openclaw/openclaw:latest

USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends docker-ce-cli \
    && rm -rf /var/lib/apt/lists/*
