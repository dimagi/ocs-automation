# session/Dockerfile
# Claude Code session container for open-chat-studio tasks
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    git curl unzip jq \
    python3 python3-pip python3-venv \
    chromium-browser \
    postgresql-client \
    && rm -rf /var/lib/apt/lists/*

# Node.js v24 (for Claude Code + acpx)
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# uv (Python package manager)
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="/root/.cargo/bin:/root/.local/bin:/home/coder/.local/bin:$PATH"

# Claude Code CLI
RUN npm install -g @anthropic-ai/claude-code

# acpx (headless ACP client)
RUN npm install -g acpx

# Create non-root user (Claude Code refuses to run as root)
RUN useradd --create-home --shell /bin/bash coder \
    && mkdir -p /workspace \
    && chown coder:coder /workspace

WORKDIR /workspace

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

USER coder
ENTRYPOINT ["/entrypoint.sh"]
