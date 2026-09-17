# Remote agent host

A machine with Docker runs Claude Code sessions unattended: any skill, any prompt, any project, several at a time. A client dispatches the project's `cloud` workflow with a branch and a prompt; a self-hosted runner on the host brings the project's `docker-compose.yml` up, runs the session in a container from this repository's image, and, when the session ends, pushes the branch and opens a draft pull request. The container is the boundary: no key, no sudo, no published port, no Docker socket, so the host keeps serving whatever else it serves.

![Architecture: triggers, GitHub, the VPS with two runners, and the Claude app](docs/architecture.svg)

The trigger is anything with `gh`: a laptop, the Actions tab, another workflow, a bot. The runner is a process on the host that runs the job's steps: `docker compose up` on the project's own `docker-compose.yml`, then `docker run` of the agent image on the same network, where `session` runs `claude --bg --remote-control` on the checked-out branch. Only what `docker-compose.yml` declares (Postgres, in the figure) is a container next to the agent's; the API and the web dev server are processes the session starts from the repository's own instructions, next to `claude` and headless Chromium. One job per runner, each with its own network, sidecars, checkout and session; the same branch queues behind itself, different branches run in parallel; only `/opt/agent/home` and the runner pool are shared. The session is watched, answered and, if needed, stopped from the Claude app over Remote Control.

| File | Does |
| :- | :- |
| `Dockerfile` | the image: Node, pnpm, Chromium, a pinned Claude Code and chrome-devtools MCP, `session`, an unprivileged user, git identity and ignore |
| `session` | the one step of a run, inside the container: sandbox off, the client's hooks and status line dropped, the plugin registries pointed at this home, the MCP registered, `claude --bg --remote-control` on the checkout, polled until it ends |
| `workflow.yml` | the template a project copies to `.github/workflows/cloud.yml`: the configuration, the sidecars, the session, the teardown, the push and the pull request |
| `.github/workflows/image.yml` | builds the image on every push to `main`, runs `test.sh`, pushes `ghcr.io/qrafttech/agent` |
| `test.sh [image]` | `session` against a stubbed `claude`; with `image`, builds the image and checks the pins |
| `docs/` | the two figures of this README |

Why a host and not a Claude Code cloud session: a session that verifies its work needs the app's database, API, web server and a browser, and brings them up itself. Why GitHub Actions and not a script: the runner, the checkout, the secrets, the queue, the logs, the token that pushes and the cancel button exist already; what is left is one step. Why that step runs Docker itself and not the runner's `container:` and `services:`: the runner would mount the host's Docker socket into the session's container, unconditionally, and would need every sidecar retyped; `docker compose up` and `docker run` give the session a container with nothing of the host in it and the project's `docker-compose.yml` untouched.

## 1. Layout

On the host, one user, `agent`, uid 1000 (the image's user), in the `docker` group, the one you ssh as. It owns the runners and one directory that knows nothing about any project:

```
/opt/agent/home/       the agent's $HOME in the container, shared by every run: the login, plus the client's `~/.claude` at `HEAD` and its `plugins/`
~/runner-<repo>-<n>/   one GitHub Actions runner, a systemd service; one per concurrent run, per repository; its _work/ holds the checkout during a run
```

One run is one job on one of those runners:

```
job                                          steps on the host, as the runner's user; one Compose project per job, cloud-<run id>
├─ docker compose up -d --wait                  the project's docker-compose.yml as is, ports unpublished: postgres, healthy, on network cloud-<run id>_default
├─ docker run … agent session …                 ghcr.io/qrafttech/agent on that network; /home/agent from the host, the checkout's parent directory at its host path
│  └─ session <repo>/<branch> "<prompt>"        the container's process, behind docker-init; launches the session, holds the step
│     └─ claude --bg --remote-control           the session, a plain process in the checkout
│        ├─ API, web dev server                 started by the session from the repository's own instructions
│        └─ Chromium, headless                  spawned by the chrome-devtools MCP
└─ docker compose down -v · commit · push · PR  the last step, on the host, always
```

The session is a process, not a nested container. The sidecars are the one thing it does not start: the job brought them up as Compose project `cloud-<run id>`, under their service names, every `ports:` reset by an override generated from `docker compose config --services`, and the prompt says so. The Claude sandbox stays off because on Linux it gives every Bash command its own network namespace, so a server started in one command is unreachable from the next; the container is the boundary instead. `docker run` mounts `/opt/agent/home` and the checkout's parent directory, joins the job's network, passes the job's `env:` key by key, and nothing else. The parent directory and not the checkout: pnpm keeps a store at the top of the checkout's mount, which would be inside the checkout, 80,000 files for `git add -A`; at the top of the parent's it sits next to the checkout, on the host, kept from one run to the next.

Runs do not collide: each job has its own Compose project, network, volumes and checkout, so `postgres:5432` is its own database in every container. The shared `home/` is safe the way several terminals on one machine are: one login serves any number of sessions, and session state is keyed by checkout path, the same on every run of a runner. The container runs as uid 1000, the runner's user, so host and container both own what a run writes. The host's firewall does not change.

## 2. Install (once per host)

```bash
ssh root@vps 'curl -fsSL https://get.docker.com | sh && apt install -y git jq \
  && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
  && echo "deb [signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
  && apt update && apt install -y gh \
  && useradd -m -u 1000 -G docker agent && install -d -o agent -g agent -m 700 /opt/agent /opt/agent/home'
```

Docker from Docker's script because Debian's `docker.io` lacks Compose v2, and `up --wait` with the `!reset` override needs Compose 2.24 or later; `git` for the checkout and the last step, `jq` for the session step, `gh` for the pull request. Give `agent` your SSH key and passwordless `sudo` for the service install below.

One runner per concurrent run, per repository; the registration token comes from the client, where `gh` is admin on `owner/repo`, and is good for an hour:

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

The runners appear under Settings → Actions → Runners, idle; each starts with the box and takes one job at a time. The image is pulled from GHCR at every job (`image.yml` pushes `ghcr.io/qrafttech/agent`, amd64, on every push to `main`): set the package public once after the first push, or `ssh agent@vps docker login ghcr.io` with a token that reads packages.

## 3. What only hands can do

1. **Login**, once per host: `ssh -t agent@vps 'docker run --rm -it -v /opt/agent/home:/home/agent ghcr.io/qrafttech/agent claude'`, `/login`, the URL in a browser, the code back. The credentials land in `home/.claude/.credentials.json`, `-rw-------`, and stay there; never copy that file. Keep `ANTHROPIC_API_KEY` unset: Remote Control needs the subscription.
2. **Your Claude setup**, once and whenever it changes: the committed tree of `~/.claude` (`settings.json`, `CLAUDE.md`, `rules/`, `skills/`, `commands/`, `agents/`), and `plugins/` as is, into `home/.claude/`; `enabledPlugins` in that `settings.json` says which plugins are on. What is not committed does not travel, so commit first. Nothing else under `home/.claude/` is touched, the login in particular. The copy is never edited by hand: every session start adapts it (§7), a session may update a marketplace, and the next sync puts both back.
   ```bash
   git -C ~/.claude archive HEAD | ssh agent@vps "cd /opt/agent/home/.claude && rm -rf $(git -C ~/.claude ls-tree --name-only HEAD | xargs) && tar x"
   rsync -a --delete ~/.claude/plugins/ agent@vps:/opt/agent/home/.claude/plugins/
   ```
3. **The project's workflow**, once per project: `workflow.yml` from here at `.github/workflows/cloud.yml`, its `env:` filled with the keys of the project's `.env.example` files, each service of `docker-compose.yml` at its service name (`postgres:5432`, not `localhost`). Dev values go in the file; anything that must not be in the tree is a repository secret, `gh secret set NAME`, read as `${{ secrets.NAME }}`. Dev credentials only. The workflow must be on `main` for `gh workflow run` to find it, and on the branch it runs.
4. **The repository's settings**, once per project: Settings → Actions → General → "Allow GitHub Actions to create and approve pull requests", on. Protect `main`, so the job's token can only ever add a branch.

## 4. A run

![A run in six steps: push and dispatch, queue, checkout and containers up, session, teardown and push and draft pull request, review](docs/run.svg)

```bash
gh workflow run cloud --ref feat/x -f prompt="Run the implement-loop skill against .claude/deliverable.md"
gh workflow run cloud --ref feat/x -f prompt="$(cat plan.md)"    # a file as the prompt: what is not pushed does not travel
```

Or as a shell function, run from inside the project's checkout; the words after the branch are the prompt:

```zsh
cloud() {
  [ $# -ge 2 ] || { echo "usage: cloud <branch> <prompt...>" >&2; return 1; }
  local branch=$1; shift
  gh workflow run cloud --ref "$branch" -f prompt="$*"
}
```

The job checks the branch out without keeping the token, brings `docker-compose.yml` up, and runs `session <repo>/<branch> "<prompt>"` in the agent container with the job's `env:` passed through. `session` launches `claude --bg --name <repo>/<branch> --remote-control <repo>/<branch> --permission-mode auto`, then polls `claude agents --json --all` every 30 s until the session is neither `working` nor `blocked`; three listings in a row that fail or lack the session end the step with an error. Your prompt is preceded by three lines: this is a run of the project in its own container and the app's configuration is in the environment; the services `docker-compose.yml` declares are already up under their names, so do not start Docker, bring the rest of the stack up from the repository's own instructions and stop what you started (a repository without `docker-compose.yml` is told to bring the whole stack up); commit your work on this branch as you go, with real messages, and do not push.

**Code → `<repo>/<branch>`** in the Claude app is where the run is watched, answered and stopped. `gh run watch` shows the job; `gh run list --workflow cloud` the queue.

## 5. The end

Nothing to do on the client. The last step runs `if: always()`, so after a session that ended, was stopped in the app, cancelled or timed out: it removes the agent container if a cancel left it, takes the Compose project down with its volumes, commits whatever the session left uncommitted as `run: <branch>` (`*.log`, `*.tmp`, `*.pid` excepted), pushes the branch with the job's token, and opens a draft pull request titled with the prompt's first line and bodied with the prompt, or leaves the one already open on that branch alone. A run that changed nothing pushes nothing: `no changes on <branch>` in the job log. Then `git pull`, review, mark ready.

Cancelling: stop the session in the Claude app and the poll sees it end within 30 s. `gh run cancel <id>` is the hard way: the runner signals the step, `docker run` forwards it to `session`, which stops and removes the Claude session; the last step still commits and pushes. `timeout-minutes` is 23 hours because the job's token lives 24 at most; a session `blocked` on a question nobody answers holds a runner until then.

## 6. Looking at the host

```bash
gh run list --workflow cloud                                    # every run, queued, going or finished
gh run view <id> --log | tail -50                               # what session printed: the id, how it ended
ssh agent@vps 'docker ps --format "{{.Names}}\t{{.Status}}"'   # cloud-<run id> is the agent, cloud-<run id>-postgres-1 a sidecar
ssh agent@vps 'sudo systemctl status "actions.runner.*"'       # the runners
```

A session's own screen is in the Claude app; `claude logs <id>` inside the container is `docker exec cloud-<run id> claude logs <id>` on the host.

## 7. Upgrading

- **Claude Code, pnpm, the MCP, `session`**: change the `ARG` in the `Dockerfile` or the script, `bash test.sh` and `bash test.sh image`, push to `main`; the next job pulls the new image. Then one probe on a scratch branch: `gh workflow run cloud --ref probe -f prompt="Bring the stack up, open the web app in Chrome through the chrome-devtools MCP, report document.title, then stop everything you started"`. That run is the only test of the job's network, Chromium, Remote Control, the plugins and the workspace trust on the real host. `session` reads `backgrounded · <id>` and the `working`/`blocked` states from the CLI, and fails loudly after three polls when they change, rather than reporting no changes.
- **Docker, Compose, `git`, `jq`, `gh`**: `apt upgrade`, as root. **The runners** update themselves; `./config.sh remove --token <token>` unregisters one.
- **Your Claude setup**: the two lines of §3.2. Every session start also adapts the mirrored copy: in `settings.json`, the sandbox off, `hooks` and `statusLine` dropped since they name commands of the client, the chrome-devtools MCP registered with the image's Chromium; in the two plugin registries, the client's `~/.claude/plugins/` paths rewritten to the container's. Everything else applies as on the client, `permissions.ask` included: a rule that prompts on the client prompts in the app.
- **Rotate the login**: `/logout` then `/login` as in §3.1, twice a year, and after any doubt about the box.

## 8. What the container has and never has

Has: the image, `home/` with the login and the mirrored setup, the checkout of one branch, the sidecars on the job's network, the app's configuration in the environment, outbound network. Never has: a token (the checkout keeps none; the job's is only in the last step, on the host, after the container is gone), a way to push, another repository, sudo, a published port, a real credential, the client's `~/.claude.json`, the host's Docker socket. What does have Docker is the runner's user, and so the steps of `cloud.yml` on the dispatched branch: a session can edit that file, so read the diff of `.github/` in the pull request before dispatching the branch again.

## 9. What the probes proved, and what is left

Four probe runs on MyKarate (`Bring the stack up, open the web app in Chrome, report document.title, then stop`) settle what the stubs cannot:

- `docker run --pull always` pulls the image; a public package needs no login. The checkout, written by the runner's uid 1000, is writable by the image's user; `HOME` stays `/home/agent`, where the login is mounted. The mirrored plugins load with `enabledPlugins` from the mirrored `settings.json`.
- The session runs `pnpm install`, the migrations, the API and the web dev server as processes, and headless Chromium renders the app via the MCP. A `.env` it tries to write may be denied; the environment is authoritative and it falls back to it. A crashing child would leave a `core` file for `git add -A`; `session` runs `ulimit -c 0`.
- `docker compose up --wait` with the `!reset` override on Compose v5, Postgres healthy in 6 s; `toJSON(env)` is the job's `env:` and nothing else, so the prompt is not in the container's environment; the last step takes the project down, commits, pushes and opens the pull request from the host.
- With the checkout alone mounted, a run committed `.pnpm-store/`, 83,410 files; with the parent directory mounted, the next probe printed `no changes on probe`, no pull request, no container, volume or network left. The session was listed under Code in the Claude app while it ran.
- `gh run cancel` a minute into the session: the step ended within 3 s, the last step printed `no changes on probe`, `claude agents --json --all` in the shared home lists nothing, and the session vanished from the app, which is `session`'s trap (`claude stop`, then `claude rm`) and what a killed container would not do.

- With the plugins in `home/.claude/plugins/` and no seed, the same probe went green: `session … done` after 2.5 min, `no changes on probe`.

Left: a `blocked` session answered from the app; the sessions were watched there, none was asked a question.
