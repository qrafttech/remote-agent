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

T=$(cd "${TMPDIR:-/tmp}" && pwd -P)/cloud-test.$$; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/stubs" "$T/agent/home/.claude" "$T/home/.claude" "$T/mac-claude/skills/s" "$T/mac-claude/plugins/cache/m/p/1" "$T/mac-claude/plugins/marketplaces/m" "$T/mac-claude/plugins/repos"
echo '{"a":1}' > "$T/mac-claude/settings.json"; echo s > "$T/mac-claude/skills/s/SKILL.md"; echo m > "$T/mac-claude/plugins/known_marketplaces.json"; echo p > "$T/mac-claude/plugins/cache/m/p/1/plugin.json"; echo r > "$T/mac-claude/plugins/repos/r"
echo cred > "$T/agent/home/.claude/.credentials.json"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t LC_ALL=C
export CLOUD_HOST= AGENT_ROOT=$T/agent CLAUDE_CONFIG_DIR=$T/mac-claude STUBS=$T/stubs STUBLOG=$T/stub.log
cat > "$STUBS/docker" <<'EOF2'
#!/usr/bin/env bash
echo "docker $*" >> "$STUBLOG"
case "$1 $2" in
  "image inspect") [ -z "${NO_IMAGE:-}" ] ;;
  "ps -aq") [ ! -e "$AGENT_ROOT/container" ] || echo abc ;;
  "inspect -f") [ ! -e "$AGENT_ROOT/running" ] || echo true ;;
  "compose --project-directory") [ -z "${STUBFAIL_compose:-}" ] ;;
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

git switch -q -c feat/x; echo edit >> f.txt; mkdir -p apps .claude; echo plan > apps/plan.md; echo d > .claude/deliverable.md
head=$(git rev-parse HEAD)
o=$(out cloud run x); check "run without env on the host: refused, nothing pushed" 'grep -q "write .*env on the host" <<<"$o" && ! git rev-parse -q --verify refs/cloud/feat/x >/dev/null'
touch "$proj/env"
o=$(NO_IMAGE=1 out cloud run x); check "run without the image: refused" 'grep -q "cloud build" <<<"$o"'
: > "$STUBLOG"
o=$(cd apps && out cloud run plan.md)
input=$(git rev-parse refs/cloud/feat/x)
check "run: the branch is untouched and the tree still dirty" '[ "$(git rev-parse HEAD)" = "$head" ] && [ -n "$(git status --porcelain)" ]'
check "run: run/feat/x in the host's bare repo is the input commit, with the edit, the file, .claude/ and the prompt" '[ "$(git -C "$proj/repo.git" rev-parse run/feat/x)" = "$input" ] && git ls-tree -r --name-only "$input" | grep -qx apps/plan.md && git ls-tree -r --name-only "$input" | grep -qx .claude/deliverable.md && git show "$input:f.txt" | grep -qx edit'
check "run: prompt names the project, the compose services and the file" 'git show "$input:.claude/prompt.txt" | head -1 | grep -q "^This is a run of mac in its own container" && git show "$input:.claude/prompt.txt" | grep -q "docker-compose.yml declares are already up" && git show "$input:.claude/prompt.txt" | tail -1 | grep -qx "Implement apps/plan.md"'
check "run: tooling, overlay and stack shipped to the host" 'cmp -s "$here/cloud" "$AGENT_ROOT/cloud" && cmp -s "$here/agent.yml" "$AGENT_ROOT/agent.yml" && cmp -s "$here/Dockerfile" "$AGENT_ROOT/Dockerfile" && cmp -s cloud.yml "$proj/cloud.yml" && cmp -s docker-compose.yml "$proj/stack.yml"'
check "run: settings, skills and the plugin seed shipped, the rest of home untouched" '[ "$(cat "$AGENT_ROOT/home/.claude/settings.json")" = "{\"a\":1}" ] && [ -f "$AGENT_ROOT/home/.claude/skills/s/SKILL.md" ] && [ -f "$AGENT_ROOT/seed/known_marketplaces.json" ] && [ -f "$AGENT_ROOT/seed/cache/m/p/1/plugin.json" ] && [ -d "$AGENT_ROOT/seed/marketplaces/m" ] && [ ! -e "$AGENT_ROOT/seed/repos" ] && [ -f "$AGENT_ROOT/home/.claude/.credentials.json" ]'
rm -r "$T/mac-claude/skills/s"; o=$(out cloud run again)
check "run: a skill removed on the Mac leaves the host" '[ ! -e "$AGENT_ROOT/home/.claude/skills/s" ]'
check "run: one compose project per run, started detached with the session command" 'grep -q "^docker compose --project-directory $proj -p mac-feat-x -f $proj/stack.yml -f $proj/cloud.yml run -d --quiet-pull --name mac-feat-x agent cloud session mac feat/x$" "$STUBLOG"'

check "run twice: refused" 'grep -q "is out" <<<"$o"'
git stash -q -u; git switch -q -c feat/y; touch "$AGENT_ROOT/container"
o=$(out cloud run second); check "run while the host holds this branch: refused" 'grep -q "holds mac-feat-y" <<<"$o" && ! git rev-parse -q --verify refs/cloud/feat/y >/dev/null'
rm "$AGENT_ROOT/container"; git switch -q feat/x; git branch -qD feat/y; git stash pop -q

: > "$STUBLOG"
o=$(AGENT_WRITES=agent.txt session feat/x)
check "session: worktree on run/feat/x, result committed there, session removed" 'git -C "$proj/repo.git" worktree list | grep -q "runs/feat-x .*\[run/feat/x\]" && grep -q "has the result" <<<"$o" && git -C "$proj/repo.git" ls-tree --name-only run/feat/x | grep -qx agent.txt && grep -q "^claude rm abc123$" "$STUBLOG"'
check "session: sandbox off, chrome-devtools registered, prompt from the tree, named project/branch" 'node -e "process.exit(require(\"$T/home/.claude/settings.json\").sandbox.enabled===false?0:1)" && grep -q "^claude mcp add --scope user chrome-devtools -- chrome-devtools-mcp --headless --isolated --executablePath /usr/local/bin/chromium$" "$STUBLOG" && tail -1 "$AGENT_ROOT/claude.prompt" | grep -qx "Implement apps/plan.md" && grep -q "^claude --bg --name mac/feat/x --remote-control mac/feat/x --permission-mode auto " "$STUBLOG"'

o=$(out cloud pull); check "pull: refuses a dirty tree" 'grep -q "commit or stash first" <<<"$o"'
git add -A; git commit -qm mine
touch "$AGENT_ROOT/running"
o=$(out cloud pull); check "pull while running: refused, nothing applied" 'grep -q "still going" <<<"$o" && [ -z "$(git status --porcelain)" ]'
rm "$AGENT_ROOT/running"; : > "$STUBLOG"
o=$(out cloud pull)
check "pull: the agent delta is staged and uncommitted, the prompt is not" 'grep -q "^A  agent.txt" <<<"$(git status --porcelain)" && [ ! -e .claude/prompt.txt ]'
check "pull: container, compose project, worktree, branch and ref gone" 'grep -q "^docker rm -f mac-feat-x$" "$STUBLOG" && grep -q "^docker compose .* -p mac-feat-x .* down -v --remove-orphans$" "$STUBLOG" && [ ! -e "$proj/runs/feat-x" ] && ! git -C "$proj/repo.git" show-ref -q refs/heads/run/feat/x && ! git rev-parse -q --verify refs/cloud/feat/x >/dev/null'
git commit -qm keep

run_x; o=$(session feat/x)
check "session, no changes: says so" 'grep -q "no changes" <<<"$o"'
o=$(out cloud pull); check "pull after a no-change run: reports it and cleans" 'grep -q "produced no changes" <<<"$o" && [ ! -e "$proj/runs/feat-x" ] && ! git rev-parse -q --verify refs/cloud/feat/x >/dev/null'

echo p > .claude/plan.md
run_x .claude/plan.md
check "run with an ignored file: in the input commit, not on the branch" 'git ls-tree -r --name-only refs/cloud/feat/x | grep -qx .claude/plan.md && ! git ls-tree -r --name-only HEAD | grep -q "^.claude/"'
AGENT_WRITES=later.txt session feat/x >/dev/null
echo mine > mine.txt; git add -A; git commit -qm moved
o=$(out cloud pull)
check "pull: warns when the branch moved and still applies" 'grep -q "moved since the run" <<<"$o" && grep -q "^A  later.txt" <<<"$(git status --porcelain)"'
git commit -qm k2

run_x; AGENT_WRITES=n.txt session feat/x >/dev/null
o=$(STUBFAIL_compose=1 out cloud pull)
check "pull with a failing host cleanup: delta staged, branch and ref kept" 'grep -q "^A  n.txt" <<<"$(git status --porcelain)" && git -C "$proj/repo.git" show-ref -q refs/heads/run/feat/x && git rev-parse -q --verify refs/cloud/feat/x >/dev/null'
o=$(STUBFAIL_compose=1 out cloud clean)
check "clean with a failing host cleanup: says so, keeps the branch and the ref" 'grep -q "host cleanup failed" <<<"$o" && git -C "$proj/repo.git" show-ref -q refs/heads/run/feat/x && git rev-parse -q --verify refs/cloud/feat/x >/dev/null'
o=$(out cloud clean)
check "clean afterwards: completes and is idempotent" '! git -C "$proj/repo.git" show-ref -q refs/heads/run/feat/x && ! git rev-parse -q --verify refs/cloud/feat/x >/dev/null && cloud clean >/dev/null 2>&1'
git commit -qm k3

run_x; AGENT_WRITES=b.png session feat/x >/dev/null
git -C "$proj/runs/feat-x" checkout -q run/feat/x; printf '\x89PNG\x00\x01' > "$proj/runs/feat-x/b.png"; git -C "$proj/runs/feat-x" commit -qam binary
echo dirty > "$proj/runs/feat-x/dirty.txt"
o=$(out cloud pull); check "pull with uncommitted work in the worktree: refused, nothing applied" 'grep -q "uncommitted work" <<<"$o" && [ -z "$(git status --porcelain)" ] && git rev-parse -q --verify refs/cloud/feat/x >/dev/null'
rm "$proj/runs/feat-x/dirty.txt"
o=$(out cloud pull); check "pull: a binary file the run added is staged" 'grep -q "^A  b.png" <<<"$(git status --porcelain)" && cmp -s b.png <(printf "\x89PNG\x00\x01")'
git commit -qm k4

git rm -q docker-compose.yml; git commit -qm nostack; run_x
check "run without docker-compose.yml: the stale stack leaves the host, the prompt says so" '[ ! -e "$proj/stack.yml" ] && git show refs/cloud/feat/x:.claude/prompt.txt | grep -q "^Bring the stack up yourself" && grep -q "^docker compose --project-directory $proj -p mac-feat-x -f $proj/cloud.yml run " "$STUBLOG"'
session feat/x >/dev/null; cloud pull >/dev/null 2>&1; git revert --no-edit HEAD >/dev/null

git remote remove origin
o=$(out cloud run x); check "no origin remote: refused" 'grep -q "no origin remote" <<<"$o" && [ ! -e "$AGENT_ROOT/projects/repo.git" ]'
git remote add origin git@github.com:someone/Mac.git

git checkout -q --detach
o=$(out cloud run x); check "detached HEAD: refused" 'grep -q "detached" <<<"$o"'
git switch -q feat/x

git switch -q -c 'feat/$x'
CLOUD_HOST=stub run_x
check "over ssh, a branch name with \$ reaches the host intact" 'git -C "$proj/repo.git" show-ref -q "refs/heads/run/feat/\$x"'
session 'feat/$x' >/dev/null; CLOUD_HOST=stub cloud pull >/dev/null 2>&1
check "over ssh: pull cleans the same" '! git -C "$proj/repo.git" show-ref -q "refs/heads/run/feat/\$x" && [ ! -e "$proj/runs/feat--x" ]'
git switch -q feat/x; git branch -qD 'feat/$x'

run_x
o=$(CLAUDE_AGENTS='[]' session feat/x)
check "session that never appears: the run errors and commits nothing" 'grep -q "missing .* three times" <<<"$o" && [ "$(git -C "$proj/repo.git" rev-parse run/feat/x)" = "$(git rev-parse refs/cloud/feat/x)" ]'
cloud clean >/dev/null 2>&1; run_x; : > "$STUBLOG"
o=$(CLAUDE_AGENTS='oops' AGENT_WRITES=w.txt session feat/x)
check "listing that fails: the run errors after three strikes, stops the session, commits what exists" 'grep -q "error .* three times" <<<"$o" && grep -q "^claude stop abc123$" "$STUBLOG" && git -C "$proj/repo.git" ls-tree --name-only run/feat/x | grep -qx w.txt'
cloud clean >/dev/null 2>&1; run_x
( HOME=$T/home POLL=60 CLAUDE_AGENTS='[{"id":"abc123","state":"working"}]' AGENT_WRITES=half.txt exec bash "$AGENT_ROOT/cloud" session mac feat/x >"$T/term.out" 2>&1 ) &
pid=$!; until grep -q "running" "$T/term.out" 2>/dev/null; do sleep 0.1; done; kill -TERM "$pid"; wait "$pid"
check "docker stop: SIGTERM makes the session stop claude and commit what exists" 'grep -q "has the result" "$T/term.out" && grep -q "^claude stop abc123$" "$STUBLOG" && git -C "$proj/repo.git" ls-tree --name-only run/feat/x | grep -qx half.txt'
cloud pull >/dev/null 2>&1

verdict cloud
