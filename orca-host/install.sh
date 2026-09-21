#!/usr/bin/env bash
# orca-host — install Orca headless server on a fresh Debian 12 VM. Run as root. Idempotent.
# Source: https://github.com/stablyai/orca/blob/main/docs/reference/headless-linux-server.md
#
# Network: the VM joins the Tailscale tailnet and `orca serve` advertises its tailnet IP. Clients (desktop,
# mobile) pair over the tailnet; nothing is published on the public IP. If the VM is not yet authenticated
# on the tailnet, the script prints the login URL and stops — authenticate, then rerun it (or pass TS_AUTHKEY).
set -euxo pipefail

ORCA_VERSION="${ORCA_VERSION:-1.4.205}"   # pinned = same as the desktop client (protocol compat)
CLAUDE_CODE_VERSION="${CLAUDE_CODE_VERSION:-2.1.276}"
ORCA_PORT="${ORCA_PORT:-6768}"
TS_AUTHKEY="${TS_AUTHKEY:-}"              # optional: a Tailscale auth key for a non-interactive join
ORCA_PAIRING="${ORCA_PAIRING:-desktop}"   # desktop | mobile — which pairing link `orca serve` prints (one at a time)

# 1. System packages: Electron/Xvfb runtime deps (Debian 12 = unsuffixed lib names) + tooling
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
  curl file jq xvfb zlib1g-dev ca-certificates git lsof make \
  libgtk-3-0 libnss3 libatk1.0-0 libatk-bridge2.0-0 libgbm1 libasound2 \
  libxtst6 libcups2 libdrm2 libxkbcommon0 libpango-1.0-0 libcairo2 libatspi2.0-0 \
  libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libxrender1 libx11-xcb1 \
  libxcb-dri3-0 libxss1

# 2. Docker from Docker's script (Debian's docker.io lacks Compose >= 2.24, required by bin/worktree)
command -v docker >/dev/null || curl -fsSL https://get.docker.com | sh

# 3. GitHub CLI
if ! command -v gh >/dev/null; then
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /usr/share/keyrings/githubcli-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list
  apt-get update && apt-get install -y gh
fi

# 4. Tailscale: join the tailnet. The tailnet IP is what `orca serve` advertises, so it must exist before step 7.
command -v tailscale >/dev/null || curl -fsSL https://tailscale.com/install.sh | sh
if ! tailscale status >/dev/null 2>&1; then
  if [ -n "$TS_AUTHKEY" ]; then
    tailscale up --authkey "$TS_AUTHKEY" --hostname orca-host
  else
    set +x
    echo; echo "== Tailscale: not authenticated. Open the URL below, approve the machine, then rerun this script. =="
    timeout 20 tailscale up --hostname orca-host 2>&1 | grep -E "https://login.tailscale.com/" || true
    echo; exit 2
  fi
fi
TS_IP="$(tailscale ip -4)"

# 5. Orca AppImage, pinned, extracted once (no FUSE on the VM); a bash-login user `orca` in the docker group
#    (bin/worktree runs docker compose). Binary = /opt/orca/squashfs-root/AppRun, exposed as `orca`.
mkdir -p /opt/orca
if ! grep -q "$ORCA_VERSION" /opt/orca/VERSION 2>/dev/null; then
  rm -f /usr/local/bin/orca /opt/orca/orca-linux.AppImage
  curl -fsSL "https://github.com/stablyai/orca/releases/download/v${ORCA_VERSION}/orca-linux.AppImage" -o /opt/orca/orca-linux.AppImage
  [ "$(stat -c %s /opt/orca/orca-linux.AppImage)" -gt 100000000 ] || { echo "AppImage download looks wrong"; exit 1; }
  chmod +x /opt/orca/orca-linux.AppImage
  rm -rf /opt/orca/squashfs-root
  (cd /opt/orca && ./orca-linux.AppImage --appimage-extract >/dev/null)
  echo "$ORCA_VERSION" > /opt/orca/VERSION
fi
chown -R root:root /opt/orca
chmod -R a+rX /opt/orca
id orca >/dev/null 2>&1 || useradd --create-home --shell /bin/bash orca
usermod -aG docker orca
printf '#!/bin/sh\nexport LIBGL_ALWAYS_SOFTWARE=1\nexec /opt/orca/squashfs-root/AppRun "$@"\n' > /usr/local/bin/orca
chmod 755 /usr/local/bin/orca

# 6. Claude Code for the `orca` user, pinned (native installer, no Node needed) — Orca spawns `claude` in each worktree
sudo -u orca -H bash -c "~/.local/bin/claude --version 2>/dev/null | grep -q '^$CLAUDE_CODE_VERSION ' || curl -fsSL https://claude.ai/install.sh | bash -s -- $CLAUDE_CODE_VERSION"

# 7. systemd unit — advertised on the tailnet IP; the GCP firewall keeps the port closed on the public IP.
#    `orca serve` prints one pairing link per scope: the runtime (desktop) one by default, the mobile one with
#    --mobile-pairing. Pair the desktop first, then rerun with ORCA_PAIRING=mobile to pair a phone.
PAIRING_FLAG=""; [ "$ORCA_PAIRING" != mobile ] || PAIRING_FLAG="--mobile-pairing"
cat > /etc/systemd/system/orca-serve.service <<UNIT
[Unit]
Description=Orca runtime server
After=network-online.target docker.service tailscaled.service
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=simple
User=orca
WorkingDirectory=/home/orca
Environment=LIBGL_ALWAYS_SOFTWARE=1
ExecStart=/opt/orca/squashfs-root/AppRun serve --port ${ORCA_PORT} ${PAIRING_FLAG} --pairing-address ${TS_IP}
StandardOutput=journal
StandardError=journal
KillMode=mixed
Restart=on-failure
RestartPreventExitStatus=3
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable orca-serve.service
systemctl restart orca-serve.service
sleep 5

# 8. Report
set +x
docker --version; docker compose version; gh --version | head -1; tailscale version | head -1
echo "tailnet ip: $TS_IP"
sudo -u orca orca --version
systemctl --no-pager --lines=0 status orca-serve.service
echo; echo "Pairing link ($ORCA_PAIRING scope):"
echo "  sudo journalctl -u orca-serve -o cat | grep '^Pairing URL:' | tail -1"
echo "  desktop: Settings -> Remote Orca Servers -> Add Server, paste the URL"
echo "  mobile : ORCA_PAIRING=mobile ./install.sh, then on the laptop: qrencode -t ansiutf8 '<URL>' and scan it (phone on the tailnet)"
