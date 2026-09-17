# Remote agent host

A machine with Docker runs Claude Code sessions unattended: any skill, any prompt, any project, several at a time. You dispatch a project's `cloud` workflow with a branch and a prompt; a self-hosted runner brings the project's `docker-compose.yml` up, runs the session in a container from this repository's image, and when the session ends pushes the branch and opens a draft pull request. GitHub only dispatches, queues, holds the secrets and takes the result back — nothing runs in its cloud. The container is the boundary: no token, no sudo, no published port, no Docker socket, so the host keeps serving whatever else it serves.

![Architecture: triggers, GitHub, the VPS with two runners, and the Claude app](docs/architecture.svg)

The trigger is anything with `gh`: a laptop, the Actions tab, another workflow, a bot. Inside the container, the session is a plain process on the checked-out branch; it brings the app's own servers up from the repository's instructions, and a headless Chromium (via the chrome-devtools MCP) lets it see its work. What `docker-compose.yml` declares — a Postgres sidecar, the app itself, or nothing — is the only container next to the agent's, and the prompt adapts to each shape. One job per runner; the same branch queues behind itself, different branches run in parallel. The session is watched, answered and, if needed, stopped from the Claude app over Remote Control.

| File | Does |
| :- | :- |
| `Dockerfile` | the image: Node, pnpm, Chromium, a pinned Claude Code and chrome-devtools MCP, `session`, an unprivileged user, git identity and ignore |
| `session` | the one step of a run, inside the container: adapt the mirrored setup, launch `claude --bg --remote-control`, poll until it ends |
| `workflow.yml` | the template a project copies to `.github/workflows/cloud.yml`: configuration, sidecars, session, teardown, push and pull request |
| `.github/workflows/image.yml` | builds the image on every push to `main`, runs `test.sh`, pushes `ghcr.io/qrafttech/agent` |
| `test.sh [image]` | `session` against a stubbed `claude`; with `image`, builds the image and checks the pins |
| `AGENTS.md` | the reference: every step, state, message and refusal, the isolation model, the probe record |
| `docs/` | the two figures of this README |

`AGENTS.md` has the full anatomy of a run, what the container can and cannot reach, and why it is built this way.

## 1. Layout

On the host, one user, `agent`, uid 1000 (the image's user), in the `docker` group, the one you ssh as. It owns:

```
/opt/agent/home/       the agent's $HOME in the container, shared by every run: the login, plus your ~/.claude at HEAD and its plugins/
~/runner-<repo>-<n>/   one GitHub Actions runner, a systemd service; one per concurrent run, per repository
```

Each job gets its own network, sidecars, checkout and session; only `home/` and the runner pool are shared, and that is safe the way several terminals on one machine are.

## 2. Install (once per host)

```bash
ssh root@vps 'curl -fsSL https://get.docker.com | sh && apt install -y git jq \
  && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
  && echo "deb [signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
  && apt update && apt install -y gh \
  && useradd -m -u 1000 -G docker agent && install -d -o agent -g agent -m 700 /opt/agent /opt/agent/home'
```

Docker from Docker's script because Debian's `docker.io` lacks Compose v2, and the workflow needs Compose 2.24 or later. Give `agent` your SSH key and passwordless `sudo` for the service install below.

Then one runner per concurrent run, per repository. The registration token comes from where `gh` is admin on `owner/repo`, and is good for an hour:

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

The runners appear under Settings → Actions → Runners, idle. The image is pulled from GHCR at every job: set the `ghcr.io/qrafttech/agent` package public once after the first push, or `ssh agent@vps docker login ghcr.io` with a token that reads packages.

## 3. What only hands can do

1. **Login**, once per host: `ssh -t agent@vps 'docker run --rm -it -v /opt/agent/home:/home/agent ghcr.io/qrafttech/agent claude'`, then `/login`, the URL in a browser, the code back. The credentials land in `home/.claude/.credentials.json`, `-rw-------`, and stay there; never copy that file. Keep `ANTHROPIC_API_KEY` unset: Remote Control needs the subscription.
2. **Your Claude setup**, once and whenever it changes — the committed tree of `~/.claude`, plus `plugins/` as is. What is not committed does not travel, so commit first. Nothing else under `home/.claude/` is touched, the login in particular:
   ```bash
   git -C ~/.claude archive HEAD | ssh agent@vps "cd /opt/agent/home/.claude && rm -rf $(git -C ~/.claude ls-tree --name-only HEAD | xargs) && tar x"
   rsync -a --delete ~/.claude/plugins/ agent@vps:/opt/agent/home/.claude/plugins/
   ```
   Never edit the copy by hand: every session start adapts it (see `AGENTS.md`), and the next sync puts everything back.
3. **The project's workflow**, once per project: copy `workflow.yml` to `.github/workflows/cloud.yml` and fill its `env:` with the keys of the project's `.env.example` files — each `docker-compose.yml` service at its service name (`postgres:5432`, not `localhost`), the app's own servers at `localhost`. Dev values go in the file; anything that must not be in the tree is a repository secret, `gh secret set NAME`, read as `${{ secrets.NAME }}`. Dev credentials only — nothing that reaches a real bucket, database or mailbox. The workflow must be on `main` for `gh workflow run` to find it, and on the branch it runs. This file and a runner (§2) are the whole cost of a new project.
4. **The repository's settings**, once per project: Settings → Actions → General → "Allow GitHub Actions to create and approve pull requests", on. Protect `main`, so the job's token can only ever add a branch.

## 4. A run

![A run in six steps: push and dispatch, queue, checkout and containers up, session, teardown and push and draft pull request, review](docs/run.svg)

```bash
gh workflow run cloud --ref feat/x -f prompt="Run the implement-loop skill against .claude/deliverable.md"
gh workflow run cloud --ref feat/x -f prompt="$(cat plan.md)"    # a file as the prompt: what is not pushed does not travel
```

Or as a shell function, run from inside the project's checkout, with the prompt as its words. On `main` it pushes HEAD as a new `cloud/<date>-<prompt slug>` branch, so a run never targets `main`; on any other branch it pushes that branch and the run continues it. A dirty tree is refused, since what is not pushed does not travel. After a run on a branch, `git pull --rebase` before the next `cloud` on it.

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

The job checks the branch out, brings `docker-compose.yml` up if there is one, and runs the session in the agent container with the job's `env:` passed through. The prompt is preceded by three lines telling the session it runs in its own container, that the declared sidecars are already up (or that it must bring the whole stack up), and to commit as it goes without pushing — the exact wording, states and poll rules are in `AGENTS.md`.

**Code → `<repo>/<branch>`** in the Claude app is where the run is watched, answered and stopped. `gh run watch` shows the job; `gh run list --workflow cloud` the queue.

## 5. The end

Nothing to do on the client. The last step always runs — after a session that ended, was stopped in the app, cancelled or timed out: it tears the containers down, commits whatever the session left uncommitted as `run: <branch>`, pushes with the job's token, and opens a draft pull request titled and bodied with the prompt (or leaves the one already open alone). A run that changed nothing pushes nothing: `no changes on <branch>` in the job log. Then `git pull`, review, mark ready.

Cancelling: stop the session in the Claude app and the poll sees it end within 30 s; `gh run cancel <id>` is the hard way and the last step still commits and pushes. A session blocked on a question nobody answers holds a runner until the 23-hour timeout.

## 6. Looking at the host

```bash
gh run list --workflow cloud                                    # every run, queued, going or finished
gh run view <id> --log | tail -50                               # what session printed: the id, how it ended
ssh agent@vps 'docker ps --format "{{.Names}}\t{{.Status}}"'   # cloud-<run id> is the agent, cloud-<run id>-postgres-1 a sidecar if the project declares one
ssh agent@vps 'sudo systemctl status "actions.runner.*"'       # the runners
```

A session's own screen is in the Claude app; `claude logs <id>` inside the container is `docker exec cloud-<run id> claude logs <id>` on the host.

## 7. Upgrading

- **Claude Code, pnpm, the MCP, `session`**: change the `ARG` in the `Dockerfile` or the script, `bash test.sh` and `bash test.sh image`, push to `main`; the next job pulls the new image. Then one probe on a scratch branch: `gh workflow run cloud --ref probe -f prompt="Bring the stack up, open the web app in Chrome through the chrome-devtools MCP, report document.title, then stop everything you started"`. That run is the only test of the job's network, Chromium, Remote Control, the plugins and the workspace trust on the real host. `session` reads the CLI's output and states, and fails loudly after three bad polls when they change, rather than reporting no changes.
- **Docker, Compose, `git`, `jq`, `gh`**: `apt upgrade`, as root. **The runners** update themselves; `./config.sh remove --token <token>` unregisters one.
- **Your Claude setup**: the two lines of §3.2.
- **Rotate the login**: `/logout` then `/login` as in §3.1, twice a year, and after any doubt about the box.
