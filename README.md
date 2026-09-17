# Remote agent host

A machine with Docker runs Claude Code sessions unattended — any project, any prompt, several at a time. You dispatch a project's `cloud` workflow with a branch and a prompt. A self-hosted runner brings the project's `docker-compose.yml` up, runs the session in a container from this repository's image, then pushes the branch and opens a draft pull request. Nothing runs in GitHub's cloud. The container has no token, no sudo, no published port, no Docker socket.

![Architecture: triggers, GitHub, the VPS with two runners, and the Claude app](docs/architecture.svg)

The trigger is anything with `gh`. The session is a plain process on the checked-out branch: it starts the app's servers itself and checks its work in headless Chromium (chrome-devtools MCP). Watch, answer or stop it from the Claude app over Remote Control. The same branch queues behind itself; different branches run in parallel.

| File | Does |
| :- | :- |
| `Dockerfile` | the image: Node, pnpm, Chromium, pinned Claude Code and MCP, `session` |
| `session` | the run's one step in the container: adapt the setup, launch `claude --bg`, poll until it ends |
| `workflow.yml` | the template a project copies to `.github/workflows/cloud.yml` |
| `.github/workflows/image.yml` | builds and tests the image on every push to `main`, pushes `ghcr.io/qrafttech/agent` |
| `test.sh [image]` | `session` against a stubbed `claude`; with `image`, builds and checks the pins |
| `AGENTS.md` | what a project brings, the rules of this repository, and the reference: every step, state, message |
| `docs/` | the two figures |

## 1. Layout

One host user, `agent`, uid 1000, in the `docker` group — the one you ssh as. It owns:

```
/opt/agent/home/       the agent's $HOME in every container: the login, your ~/.claude at HEAD, its plugins/
~/runner-<repo>-<n>/   one Actions runner per concurrent run, per repository; a systemd service
```

Each job gets its own network, sidecars and checkout. Only `home/` and the runners are shared.

## 2. Install (once per host)

```bash
ssh root@vps 'curl -fsSL https://get.docker.com | sh && apt install -y git jq \
  && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
  && echo "deb [signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
  && apt update && apt install -y gh \
  && useradd -m -u 1000 -G docker agent && install -d -o agent -g agent -m 700 /opt/agent /opt/agent/home'
```

Docker from Docker's script: Debian's `docker.io` lacks Compose ≥ 2.24, which the workflow needs. Give `agent` your SSH key and passwordless `sudo`.

One runner per concurrent run. The token comes from where `gh` is admin on the repository, valid one hour:

```bash
v=$(gh release view --repo actions/runner --json tagName -q '.tagName' | tr -d v)
for n in 1 2; do
  token=$(gh api -X POST repos/owner/repo/actions/runners/registration-token -q .token)
  ssh agent@vps "mkdir -p runner-repo-$n && cd runner-repo-$n \
    && curl -fsSL https://github.com/actions/runner/releases/download/v$v/actions-runner-linux-x64-$v.tar.gz | tar xz \
    && ./config.sh --unattended --url https://github.com/owner/repo --token $token --name vps-$n \
    && sudo ./svc.sh install agent && sudo ./svc.sh start"
done
```

The runners appear under Settings → Actions → Runners. Make the `ghcr.io/qrafttech/agent` package public after the first push, or `docker login ghcr.io` on the host.

## 3. What only hands can do

1. **Login**, once per host: `ssh -t agent@vps 'docker run --rm -it -v /opt/agent/home:/home/agent ghcr.io/qrafttech/agent claude'`, then `/login`. Credentials stay in `home/.claude/.credentials.json`; never copy that file. Keep `ANTHROPIC_API_KEY` unset: Remote Control needs the subscription.
2. **Your Claude setup**, at every change. Commit first — only the committed tree travels:
   ```bash
   git -C ~/.claude archive HEAD | ssh agent@vps "cd /opt/agent/home/.claude && rm -rf $(git -C ~/.claude ls-tree --name-only HEAD | xargs) && tar x"
   rsync -a --delete ~/.claude/plugins/ agent@vps:/opt/agent/home/.claude/plugins/
   ```
   Never edit the copy by hand; every session start adapts it (see `AGENTS.md`).
3. **The project's workflow**, once per project. Copy `workflow.yml` to `.github/workflows/cloud.yml`. Fill `env:` with the keys of the project's `.env.example` files: compose services at their service name (`postgres:5432`, not `localhost`), the app's own servers at `localhost`. Dev values go in the file; anything sensitive is a repository secret (`gh secret set NAME`, read as `${{ secrets.NAME }}`). Dev credentials only. The workflow must be on `main` and on the branch it runs.
4. **Repository settings**, once per project: allow Actions to create pull requests (Settings → Actions → General); protect `main`.

## 4. A run

![A run in six steps: push and dispatch, queue, checkout and containers up, session, teardown and push and draft pull request, review](docs/run.svg)

```bash
gh workflow run cloud --ref feat/x -f prompt="Run the implement-loop skill against .claude/deliverable.md"
gh workflow run cloud --ref feat/x -f prompt="$(cat plan.md)"    # a file as the prompt
```

Or as a shell function, from inside the project's checkout. On `main` it pushes HEAD to a new `cloud/<date>-<slug>` branch; on any other branch, the run continues that branch. A dirty tree is refused: what is not pushed does not travel. After a run, `git pull --rebase` before the next one.

```zsh
cloud() {
  [ $# -ge 1 ] || { echo "usage: cloud <prompt...>" >&2; return 1; }
  [ -z "$(git status --porcelain)" ] || { echo "cloud: uncommitted changes; commit first, what is not pushed does not travel" >&2; return 1; }
  local branch=$(git branch --show-current)
  if [ "$branch" = main ]; then
    branch="cloud/$(date +%m%d-%H%M)-$(printf '%s' "$*" | tr -cs 'a-zA-Z0-9' '-' | tr 'A-Z' 'a-z' | cut -c1-40 | sed 's/-$//')"
  fi
  git push -q origin "HEAD:refs/heads/$branch" || return 1
  gh workflow run cloud --ref "$branch" -f prompt="$*"
  echo "$branch"
}
```

The session's prompt gets three preamble lines: it runs in its own container, the declared sidecars are already up (or it must bring the whole stack up), commit as you go and do not push. Exact wording in `AGENTS.md`.

Watch, answer or stop the run in the Claude app: **Code → `<repo>/<branch>`**. `gh run watch` shows the job; `gh run list --workflow cloud` the queue.

## 5. The end

Nothing to do on the client. The last step always runs, even after a cancel or timeout: it tears the containers down, commits what the session left as `run: <branch>`, pushes, and opens a draft pull request — or leaves the existing one alone. No changes → no push: `no changes on <branch>` in the log. Then `git pull`, review, mark ready.

To cancel: stop the session in the Claude app (seen within 30 s), or `gh run cancel <id>` — the last step still runs. A session blocked on an unanswered question holds its runner until the 23-hour timeout.

## 6. Looking at the host

```bash
gh run list --workflow cloud                                    # every run
gh run view <id> --log | tail -50                               # what session printed
ssh agent@vps 'docker ps --format "{{.Names}}\t{{.Status}}"'   # cloud-<run id> is the agent, cloud-<run id>-postgres-1 a sidecar
ssh agent@vps 'sudo systemctl status "actions.runner.*"'       # the runners
```

The session's own screen is in the Claude app. `claude logs <id>` runs as `docker exec cloud-<run id> claude logs <id>`.

## 7. Upgrading

- **Claude Code, pnpm, the MCP, `session`**: bump the `ARG` in the `Dockerfile` or edit the script; `bash test.sh` and `bash test.sh image`; push to `main`. Then one probe on a scratch branch: `gh workflow run cloud --ref probe -f prompt="Bring the stack up, open the web app in Chrome through the chrome-devtools MCP, report document.title, then stop everything you started"`. Only that run tests the network, Chromium, Remote Control and the plugins on the real host.
- **Docker, Compose, `git`, `jq`, `gh`**: `apt upgrade`, as root. The runners update themselves.
- **Your Claude setup**: the two lines of §3.2.
- **Rotate the login**: `/logout` then `/login` as in §3.1 — twice a year, and after any doubt about the box.
