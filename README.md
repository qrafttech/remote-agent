# Remote agent host

A machine with Docker runs Claude Code sessions unattended: any skill, any prompt, any project, several at a time. The trigger is a GitHub Actions workflow: a client dispatches it with a branch and a prompt; a self-hosted runner on the host brings the project's `docker-compose.yml` up and runs the session in a container from this repository's image; when the session ends, the job pushes the branch to GitHub and opens a draft pull request. The client is anything that can call GitHub: `gh` on a laptop, the Actions tab, another workflow, a bot; nothing of the result travels back through it. The container is the boundary: it has no key during the session, no sudo, no published port and no Docker socket, so the host can keep serving other things and nothing here touches them.

![Architecture: triggers, GitHub, the VPS with two runners, and the Claude app](docs/architecture.svg)

Any trigger with `gh` (a laptop, the Actions tab, another workflow, a bot, an issue comment) dispatches the `cloud` workflow on the project's repository. GitHub queues the job to a self-hosted runner on the VPS, a process on the host that runs the job's steps: `docker compose up` on the project's own `docker-compose.yml`, then `docker run` of the agent image on the same network, where the `session` script runs `claude --bg --remote-control` on the checked-out branch. Only what `docker-compose.yml` declares (Postgres, in the figure) runs as a container next to the agent's; the project's API (`nest start --watch` in the figure) and web dev server (`expo start --web`) are plain processes the session starts inside the job container, from the repository's own instructions, next to `claude` and headless Chromium. Two jobs of the same project run at once, one per runner, each with its own network, sidecars, checkout, processes and session; a second dispatch on the same branch queues behind the first, while different branches run in parallel, and only the host's `/opt/agent/home` and `/opt/agent/seed` mounts and the runner pool are shared. No container holds a key or token that can push: the job's last step, on the host, pushes the branch and open the draft pull request with `GITHUB_TOKEN`, while you watch, answer and, if needed, stop the session from the Claude app over Remote Control.

In the order you will do it:

1. **§2, install**, once per host: one user, one directory, one runner per concurrent run.
2. **§3, by hand**, once: log in, mirror your Claude setup, add the workflow to the project, set the repository's settings.
3. **§4, a run**: one `gh workflow run` with a branch and a prompt, watched from the Claude app.
4. **§5, the end**: the draft pull request, pulled and reviewed on the laptop.
5. **§6 to §9**: looking at the host, upgrading, what the container has, what is not verified yet.

| File | Does |
| :- | :- |
| `Dockerfile` | the image: Node, pnpm, Chromium, a pinned Claude Code and chrome-devtools MCP, the `session` script, an unprivileged user, git identity and ignore |
| `session` | the one step of a run, inside the container: sandbox off, the client's hooks and status line dropped, the MCP registered, `claude --bg --remote-control` on the checkout, polled until it ends |
| `workflow.yml` | the template a project copies to `.github/workflows/cloud.yml`: the configuration, the sidecars from `docker-compose.yml`, the session in the agent container, the teardown, the push and the pull request |
| `.github/workflows/image.yml` | builds the image on every push to `main`, runs `test.sh`, pushes `ghcr.io/qrafttech/agent` |
| `test.sh [image]` | `session` against a stubbed `claude`; with `image`, builds the image and checks the pins |
| `docs/` | the two figures of this README |

A project brings one file, `.github/workflows/cloud.yml`, with its configuration in it (§3.3); its sidecars come from its `docker-compose.yml` as is. `CLAUDE.md` details it.

Why a host and not a Claude Code cloud session: a session that verifies its work needs the app's own database, API and web server plus a browser, and brings them up itself. Why a container and not the box: the box is shared, and a container states exactly what the agent can reach. Why GitHub Actions and not a script: the runner, the checkout, the sidecars, the secrets, the queue, the logs, the token that pushes and the cancel button all exist already; what is left to write is one step. Why that step runs Docker itself and not the runner's `container:` and `services:`: the runner would mount the host's Docker socket into the session's container, unconditionally, and would need every sidecar retyped as a `services:` entry; two commands in the workflow, `docker compose up` and `docker run`, give the session a container with nothing of the host in it, and the project's `docker-compose.yml` untouched.

## 1. Layout

On the host, one user, `agent`, uid 1000 (what the image's user is), in the `docker` group, the one you ssh as. It owns the runners and one directory that knows nothing about any project:

```
/opt/agent/
├─ home/      the agent's $HOME in the container, shared by every run: the login, plus settings.json, rules/ and skills/ mirrored from the client
└─ seed/      the client's plugins, marketplaces and cache, mounted read-only as CLAUDE_CODE_PLUGIN_SEED_DIR
~/runner-<repo>-<n>/   one GitHub Actions runner, a systemd service; one per concurrent run, per repository; its _work/ holds the checkout during a run
```

One run is one job of the project's `cloud` workflow on one of those runners:

```
job                                          steps on the host, as the runner's user; one Compose project per job, cloud-<run id>
├─ docker compose up -d --wait                  the project's docker-compose.yml as is, ports unpublished: postgres, healthy, on network cloud-<run id>_default
├─ docker run … agent session …                 ghcr.io/qrafttech/agent on that network; /home/agent and /opt/seed from the host, the checkout at its host path
│  └─ session <repo>/<branch> "<prompt>"        the container's process, behind docker-init; launches the session, holds the step
│     └─ claude --bg --remote-control           the session, a plain process in the checkout
│        ├─ API, web dev server                 started by the session from the repository's own instructions
│        └─ Chromium, headless                  spawned by the chrome-devtools MCP
└─ docker compose down -v · commit · push · PR  the last step, on the host, always
```

The session runs as a process, not as a nested container. The services `docker-compose.yml` declares are the one thing it does not start: the job brought them up before it, as Compose project `cloud-<run id>`, under their service names, with every `ports:` reset by an override the step generates from `docker compose config --services`, and the prompt says so. Everything the session starts binds inside the container's own network namespace, which is why the Claude sandbox stays off: on Linux the sandbox gives every Bash command its own network namespace, so a server started in one command is unreachable from the next and from the browser. The container is the boundary instead, and the workflow builds it by hand: `docker run` mounts the two `/opt/agent` directories and the checkout, joins the job's network, passes the job's `env:` key by key, and nothing else; the runner's own `container:` would have mounted the host's Docker socket into it.

Runs do not collide: each job is its own Compose project, with its own network and volumes, so `postgres:5432` is its own database in every container, and its own checkout. Two dispatches on the same branch queue behind each other (`concurrency`). The shared `home/` is safe the way several terminals on one machine are: one login serves any number of sessions, and session state is keyed by checkout path, which is the host's path, the same on every run of that runner. The container runs as uid 1000, the runner's user, so the host and the container both own what the run writes. The host's firewall does not change.

## 2. Install (once per host)

```bash
ssh root@vps 'curl -fsSL https://get.docker.com | sh && apt install -y git jq \
  && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
  && echo "deb [signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
  && apt update && apt install -y gh \
  && useradd -m -u 1000 -G docker agent && install -d -o agent -g agent -m 700 /opt/agent /opt/agent/home /opt/agent/seed'
```

`vps` is the host. Docker comes from Docker's own script because Debian's `docker.io` has no Compose v2 plugin, and the job's `up --wait` and `!reset` override need Compose 2.24 or later; `git` is for the checkout and the last step, `jq` for the session step, `gh` for the pull request. The first user of a fresh box already has uid 1000, so `useradd -u 1000` is the whole alignment. Give `agent` your SSH key and passwordless `sudo` for the service install below.

One runner per concurrent run, per repository. `owner/repo` is the project; `n` numbers the runners; the registration token comes from the client, where `gh` is admin on the repository, and is good for an hour:

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

The runners appear under the repository's Settings → Actions → Runners, idle. Each runs as `agent`, starts with the box, and takes one job at a time; a third dispatch waits.

The image comes from GHCR, pulled by the session step at every job: `image.yml` in this repository builds and pushes `ghcr.io/qrafttech/agent` on every push to `main`. Once, after the first push, set the package public in its settings (it holds nothing but public software and `session`), or `ssh agent@vps docker login ghcr.io` with a token that reads packages. The image is amd64.

## 3. What only hands can do

1. **Login**, once per host: `ssh -t agent@vps 'docker run --rm -it -v /opt/agent/home:/home/agent ghcr.io/qrafttech/agent claude'`, `/login`, copy the URL to a browser, paste the code back. The credentials land in `home/.claude/.credentials.json`, `-rw-------`, and stay there. Never copy this file anywhere. Keep `ANTHROPIC_API_KEY` unset: Remote Control needs the subscription.
2. **Your Claude setup**, once, and again when it changes: `settings.json`, `rules/` and `skills/` into `home/.claude/`, the plugins (`known_marketplaces.json`, `marketplaces/`, `cache/`) into `seed/`. Which plugins are on comes from `enabledPlugins` in that `settings.json`. Nothing else under `home/.claude/` is touched, the login in particular. The first sync carries the plugin caches, tens of megabytes; later ones carry the difference. A changed skill, rule, setting or plugin reaches the host by running the same two lines again; the copy is never edited by hand, because every session start adapts it (§7).
   ```bash
   rsync -a --delete --include=settings.json --include='/rules/***' --include='/skills/***' --exclude='*' ~/.claude/ agent@vps:/opt/agent/home/.claude/
   rsync -a --delete --include=known_marketplaces.json --include='/marketplaces/***' --include='/cache/***' --exclude='*' ~/.claude/plugins/ agent@vps:/opt/agent/seed/
   ```
3. **The project's workflow**, once per project, in its repository at `.github/workflows/cloud.yml`: `workflow.yml` from here, with its configuration under `env:` (the keys of its `.env.example` files, each service of `docker-compose.yml` at its service name, `postgres:5432` and not `localhost`). The sidecars need nothing: the job reads `docker-compose.yml` as is. Dev values go in the file, as CI does; anything that must not be in the tree is a repository secret, `gh secret set NAME`, read as `${{ secrets.NAME }}`. Only dev credentials either way: nothing that reaches a real bucket, a real database or a real mailbox. The workflow must be on `main` for `gh workflow run` to find it, and on the branch it runs.
4. **The repository's settings**, once per project: Settings → Actions → General → "Allow GitHub Actions to create and approve pull requests", on; the job's token cannot open the draft pull request otherwise. Protect `main` so that token can only ever add a branch.

## 4. A run

![A run in six steps: push and dispatch, queue, containers up, session, push and draft pull request, teardown and review](docs/run.svg)

You push a clean branch and run one `gh workflow run` with a prompt (1). A free runner takes the job (2), checks out the branch, brings `docker-compose.yml` up and starts the agent container (3), then starts the session, which starts the API and the web dev server as processes in its container, drives headless Chromium via the MCP, works and commits as it goes, optionally watched from the Claude app (4). When the session ends, done, stopped from the app or cancelled, always-run steps commit leftovers as `run: <branch>`, push and open or reuse a draft pull request, nothing if the branch did not move (5). The containers are torn down, and you pull, review and mark the pull request ready (6).

```bash
gh workflow run cloud --ref feat/x -f prompt="Run the implement-loop skill against .claude/deliverable.md"   # a skill
gh workflow run cloud --ref feat/x -f prompt="Migrate the API tests from Jest to Vitest and make them pass"      # a plain prompt
gh workflow run cloud --ref feat/x -f prompt="$(cat plan.md)"                                                    # a file, as the prompt
```

The same, shorter, as a shell function in `~/.zshrc`, run from inside the project's checkout (`gh` takes the repository from it); the words after the branch are the prompt:

```zsh
cloud() {
  [ $# -ge 2 ] || { echo "usage: cloud <branch> <prompt...>" >&2; return 1; }
  local branch=$1; shift
  gh workflow run cloud --ref "$branch" -f prompt="$*"
}
```

```bash
cloud feat/x "Run the implement-loop skill against .claude/deliverable.md"
cloud feat/x "$(cat plan.md)"
```

The run starts from the branch as pushed to GitHub, and comes back as commits on it; what is not pushed does not travel, so a brief in an ignored `.claude/` goes in the prompt itself, as above. The job checks the branch out without keeping the token, brings `docker-compose.yml` up as Compose project `cloud-<run id>` with its ports unpublished, and runs `session <repo>/<branch> "<prompt>"` in a container of the agent image on that project's network, with the job's `env:` passed through: it launches `claude --bg --name <repo>/<branch> --remote-control <repo>/<branch> --permission-mode auto` with the prompt, then polls `claude agents --json --all` every 30 s until the session is neither `working` nor `blocked`; three listings in a row that fail or lack the session end the step with an error.

**Code → `<repo>/<branch>`** in the Claude app is where the run is watched, answered and, if needed, stopped. `gh run watch` shows the job; `gh run list --workflow cloud` the queue.

The prompt the session gets is yours, preceded by three lines: this is a run of the project in its own container and the app's configuration is in the environment; the services `docker-compose.yml` declares are already up under their names, so do not start Docker; bring the rest of the stack up from the repository's own instructions inside this checkout, and stop what you started; commit your work on this branch as you go, with real messages, and do not push. A repository without `docker-compose.yml` is told to bring the whole stack up.

## 5. The end

Nothing to do on the client. The last step runs `if: always()`, so it runs when the session ended, when it was stopped in the app, when the job was cancelled and when it timed out: it removes the agent container if a cancel left it behind, takes the Compose project down with its volumes, commits whatever the session left uncommitted as `run: <branch>` (`*.log`, `*.tmp` and `*.pid` excepted), pushes the branch with the job's token, opens a draft pull request titled with the prompt's first line and bodied with the prompt, or leaves the pull request already open on that branch alone. A run that changed nothing pushes nothing and opens nothing: `no changes on <branch>` in the job log. Then the runner is idle again.

On the client, the branch is then any other branch: `git pull`, review the pull request, mark it ready. Branch protection on `main` is what keeps the job's token to branches.

Cancelling: stop the session in the Claude app, and the poll sees it end within 30 s; the run finishes normally. `gh run cancel <id>` is the hard way: the runner signals the step, `docker run` forwards the signal to `session`, which stops the Claude session; the last step still commits and pushes. `timeout-minutes` is 23 hours because the job's token lives 24 hours at most; a session `blocked` on a question nobody answers holds a runner until then.

## 6. Looking at the host

```bash
gh run list --workflow cloud                         # every run, queued, going or finished
gh run view <id> --log | tail -50                    # what session printed: the id, how it ended
ssh agent@vps 'docker ps --format "{{.Names}}\t{{.Status}}"'   # the containers of the runs going now: cloud-<run id> is the agent, cloud-<run id>-postgres-1 a sidecar
ssh agent@vps 'sudo systemctl status "actions.runner.*"'       # the runners
```

A session's own screen is in the Claude app; `claude logs <id>` inside the container is `docker exec cloud-<run id> claude logs <id>` on the host.

## 7. Upgrading

- **Claude Code, pnpm, the MCP, `session`**: change the `ARG` in the `Dockerfile` or the script, `bash test.sh` and `bash test.sh image` on the client, push to `main`: `image.yml` rebuilds and pushes the image, and the next job pulls it. Then one probe run on a scratch branch: `gh workflow run cloud --ref probe -f prompt="Bring the stack up, open the web app in Chrome through the chrome-devtools MCP, report document.title, then stop everything you started"`. That run is the only test of the job's network, Chromium, Remote Control, the plugin seed and the workspace trust on the real host. `session` reads `backgrounded · <id>` and the `working`/`blocked` states from the CLI; a session that never appears in `claude agents --all`, or a listing that stops parsing, ends the step with an error after three polls, so a changed CLI fails loudly rather than reporting no changes.
- **Docker, Compose, `git`, `jq`, `gh` on the host**: `apt upgrade`, as root.
- **The runners**: they update themselves. `./config.sh remove --token <token>` in the runner's directory unregisters one.
- **Your Claude setup**: the two `rsync` lines of §3.2. Every session start also adapts the mirrored `settings.json`, whatever the copy says: the sandbox off, `hooks` and `statusLine` dropped since they name commands of the client, and the chrome-devtools MCP registered with the image's Chromium. Everything else in it applies as on the client, `permissions.ask` included: a rule that prompts on the client prompts in the app.
- **Rotate the login**: `/logout` then `/login` in §3.1, twice a year, and after any doubt about the box.

## 8. What the container has and what it never has

Has: the image, `home/` with the login, the mirrored settings, rules and skills, the plugin seed read-only, the checkout of one branch of one repository, the sidecars on the job's network, the app's configuration in the environment (the job's `env:`, key by key), outbound network. It never has a token: the checkout keeps none, and the job's token is only in the last step, which runs on the host after the container is gone. Never has: a way to push anywhere, another repository, sudo, a published port, a real credential, the client's `~/.claude.json` session state, the host's Docker socket. The runner's `container:` would mount `/var/run/docker.sock` into the job container unconditionally, which is why the workflow makes the container itself with `docker run`. What does have Docker is the runner's user, and so the steps of the workflow, which are lines of the dispatched branch's `cloud.yml`: a session can edit that file on its branch, so read the diff of `.github/` in the pull request before dispatching the branch again.

## 9. What a first probe proved, and what is left

A probe run on MyKarate (`Bring the stack up, open the web app in Chrome, report document.title, then stop`) went green end to end on the previous shape of the workflow, where the runner's `container:` and `services:` made the containers, and settles most of what the stubs cannot:

- **The image pull**: `docker run --pull always` pulls `ghcr.io/qrafttech/agent` at every job; a public package needs no login, a private one the `docker login` of §2 as `agent`.
- **The container's user**: the checkout, written by the runner's uid 1000, is writable by the image's. `docker run` leaves `HOME` to the image, `/home/agent`, where the login is mounted.
- **The plugin seed at runtime**: `CLAUDE_CODE_PLUGIN_SEED_DIR=/opt/seed` read-only, `enabledPlugins` from the mirrored `settings.json`.
- **The stack the session brings up**: `pnpm install`, the migrations, the API and the web dev server as processes, headless Chromium via the MCP rendering the app, then teardown. A `.env` the session tries to write may be denied; the environment is authoritative and the session falls back to it.
- **Core dumps**: a crashing child (an optional Expo devtools installer, in the probe) would leave a `core` file that the last step's `git add -A` commits; `session` runs `ulimit -c 0` so none is written.

Left, in the order it would break:

- **This shape of the workflow on the real host**: `docker compose up --wait` with the generated `!reset` override (Compose 2.24 or later), `docker run` on the Compose network, the job's `env:` passed through `toJSON(env)` and `jq`, the teardown and the push from the host. The probe of §7 is the test.
- **Remote Control listed under Code in the app**: the probe registered `claude --bg --remote-control MyKarate/probe` and ran to `done`, so it works headless; confirm the session is watchable and answerable in the app on a run you sit with.
- **A cancelled job**: whether the runner's signal reaches `docker run` and is forwarded to `session` (the trap stops the Claude session) or the container is only removed by the last step (the session dies with it). Either way the last step commits and pushes; `gh run cancel` on a probe, then the session's state in the app, tells which.
