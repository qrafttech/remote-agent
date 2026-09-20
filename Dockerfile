FROM node:24-bookworm-slim
ARG CLAUDE_VERSION=2.1.273
ARG PNPM_VERSION=10.30.1
ARG DEVTOOLS_MCP_VERSION=1.9.0
ARG GH_VERSION=2.101.0
ARG GH_STACK_VERSION=0.1.1
ARG AGENT_UID=1000

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      git curl ca-certificates rsync procps chromium fonts-liberation \
 && rm -rf /var/lib/apt/lists/*
RUN corepack disable \
 && npm install -g "pnpm@$PNPM_VERSION" "chrome-devtools-mcp@$DEVTOOLS_MCP_VERSION"
RUN curl -fsSL https://claude.ai/install.sh -o /tmp/install.sh && HOME=/opt/claude bash /tmp/install.sh "$CLAUDE_VERSION" \
 && rm /tmp/install.sh && chmod -R a+rX /opt/claude && ln -s /opt/claude/.local/bin/claude /usr/local/bin/claude
RUN curl -fsSL "https://github.com/cli/cli/releases/download/v$GH_VERSION/gh_${GH_VERSION}_linux_$(dpkg --print-architecture).deb" -o /tmp/gh.deb \
 && dpkg -i /tmp/gh.deb && rm /tmp/gh.deb \
 && install -d /opt/gh/extensions/gh-stack \
 && curl -fsSL "https://github.com/github/gh-stack/releases/download/v$GH_STACK_VERSION/linux-$(dpkg --print-architecture)" -o /opt/gh/extensions/gh-stack/gh-stack \
 && chmod a+rx /opt/gh/extensions/gh-stack/gh-stack \
 && printf 'owner: github\nname: gh-stack\nhost: github.com\ntag: v%s\nispinned: true\npath: /opt/gh/extensions/gh-stack/gh-stack\n' "$GH_STACK_VERSION" > /opt/gh/extensions/gh-stack/manifest.yml \
 && git config --system credential.helper '!gh auth git-credential'
RUN printf '#!/bin/sh\nexec /usr/bin/chromium --no-sandbox --disable-dev-shm-usage --disable-gpu "$@"\n' > /usr/local/bin/chromium \
 && chmod +x /usr/local/bin/chromium
COPY session /usr/local/bin/session
RUN git config --system user.name agent && git config --system user.email agent@cloud \
 && printf '*.log\n*.tmp\n*.pid\n' > /etc/gitignore && git config --system core.excludesFile /etc/gitignore
RUN userdel -r node && useradd -m -u "$AGENT_UID" agent

USER agent
WORKDIR /home/agent
ENV DISABLE_AUTOUPDATER=1 GH_NO_UPDATE_NOTIFIER=1
