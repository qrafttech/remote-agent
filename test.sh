#!/usr/bin/env bash
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
fails=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails+1)); fi; }
verdict() { echo; [ "$fails" = 0 ] && echo "all $1 checks passed" || { echo "$fails check(s) failed"; exit 1; }; }

if [ "${1:-}" = image ]; then
  docker build -q -t agent-test "$here" >/dev/null || exit 1
  inside() { docker run --rm agent-test bash -c "$1" 2>/dev/null; }
  eval "$(grep -oE '^ARG (CLAUDE_VERSION|PNPM_VERSION|DEVTOOLS_MCP_VERSION)=[^ ]+' "$here/Dockerfile" | sed 's/^ARG //')"
  check "claude pinned" 'inside "claude --version" | grep -q "^$CLAUDE_VERSION "'
  check "pnpm pinned" '[ "$(inside "pnpm -v")" = "$PNPM_VERSION" ]'
  check "chrome-devtools-mcp pinned" 'inside "chrome-devtools-mcp --version" | grep -q "$DEVTOOLS_MCP_VERSION"'
  check "session on the path" 'inside "session 2>&1 || true" | grep -q "^usage: session"'
  check "chromium renders headless without a sandbox" 'inside "chromium --headless --dump-dom about:blank" | grep -q "<html"'
  check "runs as uid 1000, the runner user of the host" '[ "$(inside "id -u")" = 1000 ]'
  check "git identity and ignore baked in" '[ "$(inside "git config user.name")" = agent ] && [ -z "$(inside "cd \$(mktemp -d) && git init -q . && touch a.log && git status --porcelain")" ]'
  check "autoupdater off" '[ "$(inside "echo \$DISABLE_AUTOUPDATER")" = 1 ]'
  verdict image; exit 0
fi

T=$(cd "${TMPDIR:-/tmp}" && pwd -P)/session-test.$$; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/stubs" "$T/home/.claude" "$T/repo"
echo '{"a":1,"hooks":{"Stop":[]},"statusLine":{"type":"command","command":"x"}}' > "$T/home/.claude/settings.json"
mkdir -p "$T/home/.claude/plugins"
echo '{"m":{"installLocation":"/Users/me/.claude/plugins/marketplaces/m"}}' > "$T/home/.claude/plugins/known_marketplaces.json"
echo '{"plugins":{"p@m":[{"installPath":"/Users/me/.claude/plugins/cache/m/p/1"}]}}' > "$T/home/.claude/plugins/installed_plugins.json"
export HOME=$T/home STUBS=$T/stubs STUBLOG=$T/stub.log POLL=0.1 LC_ALL=C
cat > "$STUBS/claude" <<'EOF2'
#!/usr/bin/env bash
echo "claude $*" >> "$STUBLOG"
case "$1" in
  agents) echo "${CLAUDE_AGENTS:-[]}" ;;
  mcp) [ "$2" != get ] || [ -n "${MCP_PRESENT:-}" ] ;;
  --bg) printf '%s' "${@: -1}" > "$T/claude.prompt"; echo "corelimit $(ulimit -c)" >> "$STUBLOG"; echo "backgrounded · abc123 · x" ;;
esac
EOF2
chmod +x "$STUBS"/*
export PATH=$STUBS:$PATH T
cd "$T/repo"
session() { CLAUDE_AGENTS=${CLAUDE_AGENTS:-'[{"id":"abc123","state":"done"}]'} bash "$here/session" "$@" 2>&1; }

: > "$STUBLOG"; printf 'services:\n  postgres:\n    image: postgres:17\n' > docker-compose.yml
o=$(session app/feat/x "Implement plan.md"); status=$?
check "sandbox off, hooks and status line dropped in the mounted settings, the rest kept" 'node -e "const s=require(\"$HOME/.claude/settings.json\");process.exit(s.sandbox.enabled===false&&!(\"hooks\" in s)&&!(\"statusLine\" in s)&&s.a===1?0:1)"'
check "the mirrored plugin registries point at this home, not the client's" '[ "$(node -e "console.log(require(\"$HOME/.claude/plugins/known_marketplaces.json\").m.installLocation)")" = "$HOME/.claude/plugins/marketplaces/m" ] && [ "$(node -e "console.log(require(\"$HOME/.claude/plugins/installed_plugins.json\").plugins[\"p@m\"][0].installPath)")" = "$HOME/.claude/plugins/cache/m/p/1" ]'
check "chrome-devtools registered with the image's chromium" 'grep -q "^claude mcp add --scope user chrome-devtools -- chrome-devtools-mcp --headless --isolated --executablePath /usr/local/bin/chromium$" "$STUBLOG"'
check "launched in the background, named and remote-controlled as <repo>/<branch>, permissions auto" 'grep -q "^claude --bg --name app/feat/x --remote-control app/feat/x --permission-mode auto " "$STUBLOG"'
check "core dumps off, so a crashing child leaves nothing for git add -A" 'grep -q "^corelimit 0$" "$STUBLOG"'
check "the prompt says container, sidecars up, commit as you go, then the user's prompt" 'head -1 "$T/claude.prompt" | grep -q "^This is a run of app in its own container" && grep -q "docker-compose.yml declares are already up" "$T/claude.prompt" && grep -q "do not push" "$T/claude.prompt" && tail -1 "$T/claude.prompt" | grep -qx "Implement plan.md"'
check "a done session ends the step: exit 0, session removed" '[ "$status" = 0 ] && grep -q "^session abc123 done$" <<<"$o" && grep -q "^claude rm abc123$" "$STUBLOG" && ! grep -q "^claude stop" "$STUBLOG"'

: > "$STUBLOG"; rm docker-compose.yml
MCP_PRESENT=1 session app/feat/x x >/dev/null
check "without docker-compose.yml the prompt says to bring it all up; a registered MCP is not added twice" 'grep -q "^Bring the stack up yourself" "$T/claude.prompt" && ! grep -q "mcp add" "$STUBLOG"'

o=$(CLAUDE_AGENTS='[]' session app/feat/x x); status=$?
check "a session that never appears: error after three polls" '[ "$status" = 1 ] && grep -q "missing .* three times" <<<"$o"'
: > "$STUBLOG"; o=$(CLAUDE_AGENTS=oops session app/feat/x x)
check "a listing that fails: error after three polls, the session stopped and removed" 'grep -q "error .* three times" <<<"$o" && grep -q "^claude stop abc123$" "$STUBLOG" && grep -q "^claude rm abc123$" "$STUBLOG"'

: > "$STUBLOG"
( CLAUDE_AGENTS='[{"id":"abc123","state":"working"}]' POLL=60 exec bash "$here/session" app/feat/x x > "$T/term.out" 2>&1 ) &
pid=$!; until grep -q running "$T/term.out" 2>/dev/null; do sleep 0.1; done; kill -TERM "$pid"; wait "$pid"; status=$?
check "SIGTERM (a cancelled job): the session is stopped at once, exit 143" '[ "$status" = 143 ] && grep -q "^claude stop abc123$" "$STUBLOG" && grep -q "^claude rm abc123$" "$STUBLOG"'

o=$(session x 2>&1); check "one argument: usage" 'grep -q "^usage: session" <<<"$o"'
verdict session
