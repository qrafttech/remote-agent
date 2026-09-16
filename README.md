# Remote agent host

A machine with Docker runs Claude Code sessions unattended: any skill, any prompt, any project, several at a time. The trigger is a GitHub Actions workflow: a client dispatches it with a branch and a prompt; a self-hosted runner on the host runs the job in a container from this repository's image; when the session ends, the job pushes the branch to GitHub and opens a draft pull request. The client is anything that can call GitHub: `gh` on a laptop, the Actions tab, another workflow, a bot; nothing of the result travels back through it. The container is the boundary: it has no key during the session, no Docker socket, no sudo and no published port, so the host can keep serving other things and nothing here touches them.

| File | Does |
| :- | :- |
| `Dockerfile` | the image: Node, pnpm, Chromium, `gh`, a pinned Claude Code and chrome-devtools MCP, the `session` script, an unprivileged user, git identity and ignore |
| `session` | the one step of a run, inside the container: sandbox off, the MCP registered, `claude --bg --remote-control` on the checkout, polled until it ends |
| `workflow.yml` | the template a project copies to `.github/workflows/cloud.yml`: the container, the sidecars, the configuration, the session, the push and the pull request |
| `.github/workflows/image.yml` | builds the image on every push to `main`, runs `test.sh`, pushes `ghcr.io/qrafttech/agent` |
| `test.sh [image]` | `session` against a stubbed `claude`; with `image`, builds the image and checks the pins |

A project brings one file, `.github/workflows/cloud.yml`, with its sidecars and its configuration in it (§3.3). `CLAUDE.md` details it.

Why a host and not a Claude Code cloud session: a session that verifies its work needs the app's own database, API and web server plus a browser, and brings them up itself. Why a container and not the box: the box is shared, and a container states exactly what the agent can reach. Why GitHub Actions and not a script: the runner, the checkout, the sidecars, the secrets, the queue, the logs, the token that pushes and the cancel button all exist already; what is left to write is one step.

## 1. Layout

On the host, one user, `agent`, uid 1000 (what the image's user is), in the `docker` group, the one you ssh as. It owns the runners and one directory that knows nothing about any project:

```
/opt/agent/
├─ home/      the agent's $HOME, shared by every run: the login, plus settings.json, rules/ and skills/ mirrored from the client
└─ seed/      the client's plugins, marketplaces and cache, mounted read-only as CLAUDE_CODE_PLUGIN_SEED_DIR
~/runner-<repo>-<n>/   one GitHub Actions runner, a systemd service; one per concurrent run, per repository
```

One run is one job of the project's `cloud` workflow on one of those runners:

```
job                                      one Docker network per job, nothing published
├─ container   ghcr.io/qrafttech/agent          /home/agent and /opt/seed mounted from the host, the checkout at $GITHUB_WORKSPACE
│  └─ session <repo>/<branch> "<prompt>"        the step; launches the session, holds the job
│     └─ claude --bg --remote-control           the session, a plain process in the checkout
│        ├─ API, web dev server                 started by the session from the repository's own instructions
│        └─ Chromium, headless                  spawned by the chrome-devtools MCP
└─ postgres    from `services:`                 up and healthy before the steps, gone with the job
```

The session runs as a process, not as a nested container. The services `docker-compose.yml` declares are the one thing it does not start: they are the job's `services:`, up and healthy before the first step, reachable under their names, and the prompt says so. Everything the session starts binds inside the container's own network namespace, which is why the Claude sandbox stays off: on Linux the sandbox gives every Bash command its own network namespace, so a server started in one command is unreachable from the next and from the browser. The container is the boundary instead.

Runs do not collide: each job has its own network, so `postgres:5432` is its own database in every container, and its own checkout. Two dispatches on the same branch queue behind each other (`concurrency`). The shared `home/` is safe the way several terminals on one machine are: one login serves any number of sessions, and session state is keyed by checkout path. The container runs as uid 1000, the runner's user, so the host and the container both own what the run writes. The host's firewall does not change.

## 2. Install (once per host)

```bash
ssh root@vps 'apt install -y docker.io curl && useradd -m -u 1000 -G docker agent && install -d -o agent -g agent -m 700 /opt/agent /opt/agent/home /opt/agent/seed'
```

`vps` is the host; the first user of a fresh box already has uid 1000, so `useradd -u 1000` is the whole alignment. Give `agent` your SSH key and passwordless `sudo` for the service install below.

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

The image comes from GHCR, pulled by the runner at every job: `image.yml` in this repository builds and pushes `ghcr.io/qrafttech/agent` on every push to `main`. Once, after the first push, set the package public in its settings (it holds nothing but public software and `session`), or `ssh agent@vps docker login ghcr.io` with a token that reads packages. The image is amd64.

## 3. What only hands can do

1. **Login**, once per host: `ssh -t agent@vps 'docker run --rm -it -v /opt/agent/home:/home/agent ghcr.io/qrafttech/agent claude'`, `/login`, copy the URL to a browser, paste the code back. The credentials land in `home/.claude/.credentials.json`, `-rw-------`, and stay there. Never copy this file anywhere. Keep `ANTHROPIC_API_KEY` unset: Remote Control needs the subscription.
2. **Your Claude setup**, once, and again when it changes: `settings.json`, `rules/` and `skills/` into `home/.claude/`, the plugins (`known_marketplaces.json`, `marketplaces/`, `cache/`) into `seed/`. Which plugins are on comes from `enabledPlugins` in that `settings.json`. Nothing else under `home/.claude/` is touched, the login in particular. The first sync carries the plugin caches, tens of megabytes; later ones carry the difference.
   ```bash
   rsync -a --delete --include=settings.json --include='/rules/***' --include='/skills/***' --exclude='*' ~/.claude/ agent@vps:/opt/agent/home/.claude/
   rsync -a --delete --include=known_marketplaces.json --include='/marketplaces/***' --include='/cache/***' --exclude='*' ~/.claude/plugins/ agent@vps:/opt/agent/seed/
   ```
3. **The project's workflow**, once per project, in its repository at `.github/workflows/cloud.yml`: `workflow.yml` from here, with its own sidecars under `services:` (each service of `docker-compose.yml`, same name, same image, its healthcheck as `options`, no ports) and its configuration under `env:` (the keys of its `.env.example` files, each sidecar at its service name). Dev values go in the file, as CI does; anything that must not be in the tree is a repository secret, `gh secret set NAME`, read as `${{ secrets.NAME }}`. Only dev credentials either way: nothing that reaches a real bucket, a real database or a real mailbox. The workflow must be on `main` for `gh workflow run` to find it, and on the branch it runs.
4. **The repository's settings**, once per project: Settings → Actions → General → "Allow GitHub Actions to create and approve pull requests", on; the job's token cannot open the draft pull request otherwise. Protect `main` so that token can only ever add a branch.

## 4. A run

```bash
gh workflow run cloud --ref feat/x -f prompt="Run the implement-loop skill against .claude/deliverable.md"   # a skill
gh workflow run cloud --ref feat/x -f prompt="Migrate the API tests from Jest to Vitest and make them pass"      # a plain prompt
gh workflow run cloud --ref feat/x -f prompt="$(cat plan.md)"                                                    # a file, as the prompt
```

The run starts from the branch as pushed to GitHub, and comes back as commits on it; what is not pushed does not travel, so a brief in an ignored `.claude/` goes in the prompt itself, as above. The job checks the branch out without keeping the token, brings the sidecars up, and runs `session <repo>/<branch> "<prompt>"` in the container: it launches `claude --bg --name <repo>/<branch> --remote-control <repo>/<branch> --permission-mode auto` with the prompt, then polls `claude agents --json --all` every 30 s until the session is neither `working` nor `blocked`; three listings in a row that fail or lack the session end the step with an error.

**Code → `<repo>/<branch>`** in the Claude app is where the run is watched, answered and, if needed, stopped. `gh run watch` shows the job; `gh run list --workflow cloud` the queue.

The prompt the session gets is yours, preceded by three lines: this is a run of the project in its own container and the app's configuration is in the environment; the services `docker-compose.yml` declares are already up under their names, so do not start Docker; bring the rest of the stack up from the repository's own instructions inside this checkout, and stop what you started; commit your work on this branch as you go, with real messages, and do not push. A repository without `docker-compose.yml` is told to bring the whole stack up.

## 5. The end

Nothing to do on the client. The last step runs `if: always()`, so it runs when the session ended, when it was stopped in the app, when the job was cancelled and when it timed out: it commits whatever the session left uncommitted as `run: <branch>`, pushes the branch with the job's token, opens a draft pull request titled with the prompt's first line and bodied with the prompt, or leaves the pull request already open on that branch alone. A run that changed nothing pushes nothing and opens nothing: `no changes on <branch>` in the job log. Then the job's container and sidecars go, and the runner is idle again.

On the client, the branch is then any other branch: `git pull`, review the pull request, mark it ready. Branch protection on `main` is what keeps the job's token to branches.

Cancelling: stop the session in the Claude app, and the poll sees it end within 30 s; the run finishes normally. `gh run cancel <id>` is the hard way: the last step still commits and pushes, and the container goes with the job. `timeout-minutes` is 23 hours because the job's token lives 24 hours at most; a session `blocked` on a question nobody answers holds a runner until then.

## 6. Looking at the host

```bash
gh run list --workflow cloud                         # every run, queued, going or finished
gh run view <id> --log | tail -50                    # what session printed: the id, how it ended
ssh agent@vps 'docker ps --format "{{.Names}}\t{{.Status}}"'   # the containers of the runs going now
ssh agent@vps 'sudo systemctl status "actions.runner.*"'       # the runners
```

A session's own screen is in the Claude app; `claude logs <id>` inside the container needs `docker exec` on the host, `docker ps` names it.

## 7. Upgrading

- **Claude Code, pnpm, the MCP, `gh`, `session`**: change the `ARG` in the `Dockerfile` or the script, `bash test.sh` and `bash test.sh image` on the client, push to `main`: `image.yml` rebuilds and pushes the image, and the next job pulls it. Then one probe run on a scratch branch: `gh workflow run cloud --ref probe -f prompt="Bring the stack up, open the web app in Chrome through the chrome-devtools MCP, report document.title, then stop everything you started"`. That run is the only test of the job's network, Chromium, Remote Control, the plugin seed and the workspace trust on the real host. `session` reads `backgrounded · <id>` and the `working`/`blocked` states from the CLI; a session that never appears in `claude agents --all`, or a listing that stops parsing, ends the step with an error after three polls, so a changed CLI fails loudly rather than reporting no changes.
- **The runners**: they update themselves. `./config.sh remove --token <token>` in the runner's directory unregisters one.
- **Your Claude setup**: the two `rsync` lines of §3.2. Every session start also turns the sandbox off in the mirrored `settings.json` and registers the chrome-devtools MCP with the image's Chromium, whatever the copy says.
- **Rotate the login**: `/logout` then `/login` in §3.1, twice a year, and after any doubt about the box.

## 8. What the container has and what it never has

Has: the image, `home/` with the login, the mirrored settings, rules and skills, the plugin seed read-only, the checkout of one branch of one repository, the sidecars on the job's network, the app's configuration in the environment, outbound network. During the session it has no token: the checkout keeps none, and the job's token reaches the container only in the last step, after the session is gone. Never has: a way to push anywhere during the session, another repository, the Docker socket, sudo, a published port, a real credential, the client's `~/.claude.json` session state.

## 9. Not verified yet on a real host

The stubs prove `session`; the rest waits for the first runner. In the order it would break:

- **The container job's user.** The runner starts the container from the image's `USER agent`, uid 1000, and `actions/checkout` writes into `$GITHUB_WORKSPACE`, a directory the runner created as its own user; §2 aligns them at uid 1000. If the first job says `Permission denied` on the workspace, or `claude` cannot read `/home/agent/.claude/.credentials.json`, the fix is `container.options: --user <uid of agent on the host>` plus `HOME: /home/agent` under `container.env`.
- **Remote Control from inside a job container**: `claude --bg --remote-control` under `docker exec`, with no TTY, and the session listed under **Code** in the app. Same command as before, different parent process.
- **The plugin seed at runtime**: `CLAUDE_CODE_PLUGIN_SEED_DIR=/opt/seed` read-only, `enabledPlugins` from the mirrored `settings.json`.
- **A cancelled job**: whether the runner delivers SIGTERM to `session` inside the container (the trap stops the Claude session) or only severs `docker exec` (the session dies with the container after the last step). Either way the last step commits and pushes.
- **The image pull**: the runner pulls `ghcr.io/qrafttech/agent` at every job; a private package needs the `docker login` of §2 as `agent`.
