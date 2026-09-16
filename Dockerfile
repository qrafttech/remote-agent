FROM node:24-bookworm-slim
ARG CLAUDE_VERSION=2.1.273
ARG PNPM_VERSION=10.30.1
ARG DEVTOOLS_MCP_VERSION=1.9.0
ARG AGENT_UID=1000

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      git curl ca-certificates rsync procps chromium fonts-liberation \
 && rm -rf /var/lib/apt/lists/*
RUN corepack disable \
 && npm install -g "pnpm@$PNPM_VERSION" "chrome-devtools-mcp@$DEVTOOLS_MCP_VERSION"
RUN curl -fsSL https://claude.ai/install.sh -o /tmp/install.sh && HOME=/opt/claude bash /tmp/install.sh "$CLAUDE_VERSION" \
 && rm /tmp/install.sh && chmod -R a+rX /opt/claude && ln -s /opt/claude/.local/bin/claude /usr/local/bin/claude
RUN printf '#!/bin/sh\nexec /usr/bin/chromium --no-sandbox --disable-dev-shm-usage --disable-gpu "$@"\n' > /usr/local/bin/chromium \
 && chmod +x /usr/local/bin/chromium
RUN git config --system user.name agent && git config --system user.email agent@cloud \
 && printf '*.log\n*.tmp\n*.pid\n' > /etc/gitignore && git config --system core.excludesFile /etc/gitignore
RUN userdel -r node && useradd -m -u "$AGENT_UID" agent

USER agent
WORKDIR /home/agent
ENV DISABLE_AUTOUPDATER=1
