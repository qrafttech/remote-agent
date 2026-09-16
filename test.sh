#!/usr/bin/env bash
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
fails=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails+1)); fi; }
verdict() { echo; [ "$fails" = 0 ] && echo "all $1 checks passed" || { echo "$fails check(s) failed"; exit 1; }; }

if [ "${1:-}" = image ]; then
  docker build -q -t agent-test --build-arg "AGENT_UID=$(id -u)" - < "$here/Dockerfile" >/dev/null || exit 1
  inside() { docker run --rm agent-test bash -c "$1" 2>/dev/null; }
  eval "$(grep -oE '^ARG (CLAUDE_VERSION|PNPM_VERSION|DEVTOOLS_MCP_VERSION)=[^ ]+' "$here/Dockerfile" | sed 's/^ARG //')"
  check "claude pinned" 'inside "claude --version" | grep -q "^$CLAUDE_VERSION "'
  check "pnpm pinned" '[ "$(inside "pnpm -v")" = "$PNPM_VERSION" ]'
  check "chrome-devtools-mcp pinned" 'inside "chrome-devtools-mcp --version" | grep -q "$DEVTOOLS_MCP_VERSION"'
  check "chromium renders headless without a sandbox" 'inside "chromium --headless --dump-dom about:blank" | grep -q "<html"'
  check "runs as the given uid" '[ "$(inside "id -u")" = "$(id -u)" ]'
  check "git identity and ignore baked in" '[ "$(inside "git config user.name")" = agent ] && [ -z "$(inside "cd \$(mktemp -d) && git init -q . && touch a.log && git status --porcelain")" ]'
  check "autoupdater off" '[ "$(inside "echo \$DISABLE_AUTOUPDATER")" = 1 ]'
  verdict image; exit 0
fi

T=$(cd "${TMPDIR:-/tmp}" && pwd -P)/cloud-test.$$; trap 'pkill -f "$T/agent/cloud host-finish" 2>/dev/null; rm -rf "$T"' EXIT
mkdir -p "$T/stubs" "$T/agent/home/.claude" "$T/home/.claude" "$T/mac-claude/skills/s" "$T/mac-claude/plugins/cache/m/p/1" "$T/mac-claude/plugins/marketplaces/m" "$T/mac-claude/plugins/repos"
echo '{"a":1}' > "$T/mac-claude/settings.json"; echo s > "$T/mac-claude/skills/s/SKILL.md"; echo m > "$T/mac-claude/plugins/known_marketplaces.json"; echo p > "$T/mac-claude/plugins/cache/m/p/1/plugin.json"; echo r > "$T/mac-claude/plugins/repos/r"
echo cred > "$T/agent/home/.claude/.credentials.json"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t LC_ALL=C
export CLOUD_HOST= AGENT_ROOT=$T/agent CLAUDE_CONFIG_DIR=$T/mac-claude STUBS=$T/stubs STUBLOG=$T/stub.log
git init -q --bare "$T/github.git"
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=url.$T/github.git.insteadOf GIT_CONFIG_VALUE_0=https://github.com/someone/Mac.git
cat > "$STUBS/docker" <<'EOF2'
#!/usr/bin/env bash
echo "docker $*" >> "$STUBLOG"
case "$1 $2" in
  "image inspect") [ -z "${NO_IMAGE:-}" ] ;;
  "ps -aq") [ ! -e "$AGENT_ROOT/container" ] || echo abc ;;
  "inspect -f") [ ! -e "$AGENT_ROOT/running" ] || echo true ;;
  "compose --project-directory") [ -z "${STUBFAIL_compose:-}" ] ;;
  "wait "*) until [ -e "$AGENT_ROOT/exited" ]; do sleep 0.1; done ;;
esac
EOF2
cat > "$STUBS/claude" <<'EOF2'
#!/usr/bin/env bash
echo "claude $*" >> "$STUBLOG"
case "$1" in
  agents) echo "${CLAUDE_AGENTS:-[]}" ;;
  mcp) [ "$2" != get ] ;;
  --bg) printf '%s' "${@: -1}" > "$AGENT_ROOT/claude.prompt"; [ -z "${AGENT_WRITES:-}" ] || echo agent > "$AGENT_WRITES"; echo "backgrounded · abc123 · x" ;;
esac
EOF2
cat > "$STUBS/gh" <<'EOF2'
#!/usr/bin/env bash
echo "gh $*" >> "$STUBLOG"
case "$1 $2" in
  "auth token") [ -z "${NO_GH:-}" ] ;;
  "pr list") echo "${PR_EXISTS:-}" ;;
  "pr create") echo https://github.com/someone/Mac/pull/7 ;;
esac
EOF2
cat > "$STUBS/ssh" <<'EOF2'
#!/usr/bin/env bash
while [ "$1" != stub ]; do shift; done; shift; PATH=$PATH:$(git --exec-path) exec bash -c "$*"
EOF2
chmod +x "$STUBS"/*
export PATH=$STUBS:$PATH

cd "$T" && git init -q mac && cd mac && git switch -q -c main
git remote add origin git@github.com:someone/Mac.git
printf '.claude/\n.env\n' > .gitignore; echo one > f.txt
printf 'services:\n  postgres:\n    image: postgres:17\n' > docker-compose.yml
printf 'services:\n  agent:\n    extends: { file: ${AGENT_ROOT}/agent.yml, service: agent }\n    env_file: env\n  postgres:\n    ports: !reset []\n' > cloud.yml
git add -A; git commit -qm init
proj=$AGENT_ROOT/projects/mac
cloud() { bash "$here/cloud" "$@"; }
out() { "$@" 2>&1; }
session() { ( HOME=$T/home POLL=0.1 CLAUDE_AGENTS=${CLAUDE_AGENTS:-'[{"id":"abc123","state":"done"}]'} bash "$AGENT_ROOT/cloud" session mac "$1" 2>&1 ); }
run_x() { cloud run "${1:-x}" >/dev/null 2>&1; }
ended() { touch "$AGENT_ROOT/exited"; while pgrep -f "$AGENT_ROOT/cloud host-finish" >/dev/null; do sleep 0.1; done; rm -f "$AGENT_ROOT/exited"; }
log() { cat "$proj/runs/feat-x.log"; }
pulled() { git pull -q "$T/github.git" feat/x; }

git switch -q -c feat/x; echo edit >> f.txt; mkdir -p apps .claude; echo plan > apps/plan.md; echo d > .claude/deliverable.md
o=$(out cloud run x); check "run with a dirty tree: refused, says what is dirty" 'grep -q "commit or stash first" <<<"$o" && grep -q "f.txt" <<<"$o"'
git add -A; git commit -qm work; head=$(git rev-parse HEAD)
o=$(out cloud run x); check "run without env on the host: refused, nothing pushed" 'grep -q "write .*env on the host" <<<"$o" && ! git -C "$proj/repo.git" show-ref -q refs/heads/feat/x'
touch "$proj/env"
o=$(NO_IMAGE=1 out cloud run x); check "run without the image: refused" 'grep -q "cloud build" <<<"$o"'
o=$(NO_GH=1 out cloud run x); check "run without a gh login on the host: refused" 'grep -q "gh auth login" <<<"$o"'
: > "$STUBLOG"
o=$(cd apps && out cloud run plan.md)
check "run: says where to follow it and what comes back" 'grep -q "as mac/feat/x" <<<"$o" && grep -q "draft pull request opens" <<<"$o"'
check "run: tooling, overlay and stack shipped to the host" 'cmp -s "$here/cloud" "$AGENT_ROOT/cloud" && cmp -s "$here/agent.yml" "$AGENT_ROOT/agent.yml" && cmp -s "$here/Dockerfile" "$AGENT_ROOT/Dockerfile" && cmp -s cloud.yml "$proj/cloud.yml" && cmp -s docker-compose.yml "$proj/stack.yml"'
check "run: settings, skills and the plugin seed shipped, the rest of home untouched" '[ "$(cat "$AGENT_ROOT/home/.claude/settings.json")" = "{\"a\":1}" ] && [ -f "$AGENT_ROOT/home/.claude/skills/s/SKILL.md" ] && [ -f "$AGENT_ROOT/seed/known_marketplaces.json" ] && [ -f "$AGENT_ROOT/seed/cache/m/p/1/plugin.json" ] && [ -d "$AGENT_ROOT/seed/marketplaces/m" ] && [ ! -e "$AGENT_ROOT/seed/repos" ] && [ -f "$AGENT_ROOT/home/.claude/.credentials.json" ]'
check "run: the branch is on the host's bare repository, origin recorded as https" '[ "$(git -C "$proj/repo.git" rev-parse feat/x)" = "$head" ] && [ "$(git -C "$proj/repo.git" config remote.origin.url)" = https://github.com/someone/Mac.git ]'
check "run: worktree on the branch with .claude/ and the file dropped in, untracked" 'git -C "$proj/repo.git" worktree list | grep -q "runs/feat-x .*\[feat/x\]" && [ -f "$proj/runs/feat-x/.claude/deliverable.md" ] && [ -f "$proj/runs/feat-x/apps/plan.md" ] && [ -z "$(git -C "$proj/runs/feat-x" status --porcelain)" ] && [ ! -e "$proj/inputs/feat-x" ]'
check "run: the prompt names the file, the input commit is remembered" '[ "$(cat "$proj/runs/feat-x.prompt")" = "Implement apps/plan.md" ] && [ "$(cat "$proj/runs/feat-x.input")" = "$head" ]'
check "run: one compose project per run, started detached with the session command, the waiter on it" 'grep -q "^docker compose --project-directory $proj -p mac-feat-x -f $proj/stack.yml -f $proj/cloud.yml run -d --quiet-pull --name mac-feat-x agent cloud session mac feat/x$" "$STUBLOG" && pgrep -f "$AGENT_ROOT/cloud host-finish mac feat/x" >/dev/null'
rm -r "$T/mac-claude/skills/s"; o=$(out cloud run again)
check "run twice: refused" 'grep -q "the host holds mac-feat-x" <<<"$o"'
check "every verb mirrors the setup: a skill removed on the client leaves the host" '[ ! -e "$AGENT_ROOT/home/.claude/skills/s" ]'

: > "$STUBLOG"
o=$(AGENT_WRITES=agent.txt session feat/x)
check "session: sandbox off, chrome-devtools registered, named project/branch, session removed" 'node -e "process.exit(require(\"$T/home/.claude/settings.json\").sandbox.enabled===false?0:1)" && grep -q "^claude mcp add --scope user chrome-devtools -- chrome-devtools-mcp --headless --isolated --executablePath /usr/local/bin/chromium$" "$STUBLOG" && grep -q "^claude --bg --name mac/feat/x --remote-control mac/feat/x --permission-mode auto " "$STUBLOG" && grep -q "^claude rm abc123$" "$STUBLOG"'
check "session: the prompt says container, sidecars up, commit as you go, then the user's prompt" 'head -1 "$AGENT_ROOT/claude.prompt" | grep -q "^This is a run of mac in its own container" && grep -q "docker-compose.yml declares are already up" "$AGENT_ROOT/claude.prompt" && grep -q "do not push" "$AGENT_ROOT/claude.prompt" && tail -1 "$AGENT_ROOT/claude.prompt" | grep -qx "Implement apps/plan.md"'
echo dirty > "$proj/runs/feat-x/dirty.txt"
o=$(out cloud clean); check "clean while the worktree holds uncommitted work: refused" 'grep -q "uncommitted work" <<<"$o" && [ -e "$proj/runs/feat-x" ]'
rm "$proj/runs/feat-x/dirty.txt"; : > "$STUBLOG"
ended
check "finish: the session's leftovers committed as run: feat/x, without the inputs" 'git -C "$proj/repo.git" log -1 --format=%s feat/x | grep -qx "run: feat/x" && git -C "$proj/repo.git" ls-tree --name-only feat/x | grep -qx agent.txt && ! git -C "$proj/repo.git" ls-tree -r --name-only feat/x | grep -q "^.claude/"'
check "finish: the branch pushed to GitHub, a draft PR opened from the prompt" '[ "$(git -C "$T/github.git" rev-parse feat/x)" = "$(git -C "$proj/repo.git" rev-parse feat/x)" ] && grep -q "^gh pr create --repo someone/Mac --draft --head feat/x --title Implement apps/plan.md --body-file $proj/runs/feat-x.prompt$" "$STUBLOG" && log | grep -q "^pull request https://github.com/someone/Mac/pull/7$"'
check "finish: the host cleaned itself, the log kept" 'grep -q "^docker rm -f mac-feat-x$" "$STUBLOG" && grep -q "^docker compose .* -p mac-feat-x .* down -v --remove-orphans$" "$STUBLOG" && [ ! -e "$proj/runs/feat-x" ] && [ ! -e "$proj/runs/feat-x.input" ] && [ ! -e "$proj/runs/feat-x.prompt" ] && log | grep -q "worktree removed"'
pulled
check "the client pulls the branch as any other" '[ -f agent.txt ] && [ "$(git rev-parse HEAD)" = "$(git -C "$T/github.git" rev-parse feat/x)" ]'

: > "$STUBLOG"; PR_EXISTS=https://github.com/someone/Mac/pull/7 run_x; AGENT_WRITES=more.txt session feat/x >/dev/null; ended
check "a second run on a branch with a PR: pushed, the PR reused" '[ "$(git -C "$T/github.git" rev-parse feat/x)" = "$(git -C "$proj/repo.git" rev-parse feat/x)" ] && ! grep -q "pr create" "$STUBLOG" && log | grep -q "pull/7"'
pulled

before=$(git -C "$T/github.git" rev-parse feat/x); : > "$STUBLOG"; run_x; session feat/x >/dev/null; ended
check "a run that changed nothing: no push, no PR, host cleaned" 'log | grep -q "no changes on feat/x" && [ "$(git -C "$T/github.git" rev-parse feat/x)" = "$before" ] && ! grep -q "^gh pr" "$STUBLOG" && [ ! -e "$proj/runs/feat-x" ]'

echo p > .claude/plan.md
run_x .claude/plan.md
check "run with an ignored file: in the worktree, prompt names it" '[ -f "$proj/runs/feat-x/.claude/plan.md" ] && [ "$(cat "$proj/runs/feat-x.prompt")" = "Implement .claude/plan.md" ]'
AGENT_WRITES=later.txt session feat/x >/dev/null; ended
check "run with an ignored file: not in the commit" '! git -C "$proj/repo.git" ls-tree -r --name-only feat/x | grep -q "^.claude/"'
pulled

GIT_CONFIG_KEY_0=url.$T/nowhere.git.insteadOf run_x; AGENT_WRITES=n.txt session feat/x >/dev/null; ended
check "finish with a failing push: the commit stays on the host, the worktree kept, the log says why" 'git -C "$proj/repo.git" ls-tree --name-only feat/x | grep -qx n.txt && [ -e "$proj/runs/feat-x" ] && log | grep -qi "nowhere"'
o=$(STUBFAIL_compose=1 out cloud clean)
check "clean with a failing host cleanup: says so, keeps the worktree" 'grep -q "host cleanup failed" <<<"$o" && [ -e "$proj/runs/feat-x" ]'
o=$(out cloud clean)
check "clean afterwards: completes and is repeatable" '[ ! -e "$proj/runs/feat-x" ] && cloud clean >/dev/null 2>&1'
git fetch -q "$proj/repo.git" feat/x && git merge -q --ff-only FETCH_HEAD

git rm -q docker-compose.yml; git commit -qm nostack; : > "$STUBLOG"; run_x
check "run without docker-compose.yml: the stale stack leaves the host, compose runs without it" '[ ! -e "$proj/stack.yml" ] && grep -q "^docker compose --project-directory $proj -p mac-feat-x -f $proj/cloud.yml run " "$STUBLOG"'
session feat/x >/dev/null
check "session without a stack: the prompt says to bring it all up" 'grep -q "^Bring the stack up yourself" "$AGENT_ROOT/claude.prompt"'
ended; git revert --no-edit HEAD >/dev/null

git remote remove origin
o=$(out cloud run x); check "no origin remote: refused" 'grep -q "no origin remote" <<<"$o" && [ ! -e "$AGENT_ROOT/projects/repo.git" ]'
git remote add origin git@github.com:someone/Mac.git

git checkout -q --detach
o=$(out cloud run x); check "detached HEAD: refused" 'grep -q "detached" <<<"$o"'
git switch -q feat/x

git switch -q -c 'feat/$x'
CLOUD_HOST=stub run_x
check "over ssh, a branch name with \$ reaches the host intact" 'git -C "$proj/repo.git" show-ref -q "refs/heads/feat/\$x" && [ -e "$proj/runs/feat--x" ]'
session 'feat/$x' >/dev/null; ended
check "over ssh: the waiter ends the run the same" '[ ! -e "$proj/runs/feat--x" ] && grep -q "no changes on feat/\$x" "$proj/runs/feat--x.log"'
git switch -q feat/x; git branch -qD 'feat/$x'

run_x
o=$(CLAUDE_AGENTS='[]' session feat/x)
check "session that never appears: the run errors" 'grep -q "missing .* three times" <<<"$o"'
ended
run_x; : > "$STUBLOG"
o=$(CLAUDE_AGENTS='oops' AGENT_WRITES=w.txt session feat/x)
check "listing that fails: the run errors after three strikes and stops the session" 'grep -q "error .* three times" <<<"$o" && grep -q "^claude stop abc123$" "$STUBLOG"'
ended
check "either way the waiter commits what exists" 'git -C "$proj/repo.git" ls-tree --name-only feat/x | grep -qx w.txt'
pulled

run_x; : > "$STUBLOG"
( HOME=$T/home POLL=60 CLAUDE_AGENTS='[{"id":"abc123","state":"working"}]' AGENT_WRITES=half.txt exec bash "$AGENT_ROOT/cloud" session mac feat/x >"$T/term.out" 2>&1 ) &
pid=$!; until grep -q "running" "$T/term.out" 2>/dev/null; do sleep 0.1; done; kill -TERM "$pid"; wait "$pid"
check "docker stop: SIGTERM makes the session stop claude at once" 'grep -q "^claude stop abc123$" "$STUBLOG"'
ended
check "docker stop: the waiter commits and ships the half-done work" 'git -C "$proj/repo.git" ls-tree --name-only feat/x | grep -qx half.txt && [ "$(git -C "$T/github.git" rev-parse feat/x)" = "$(git -C "$proj/repo.git" rev-parse feat/x)" ]'

verdict cloud
