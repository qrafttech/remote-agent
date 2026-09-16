# Remote agent host

A machine with Docker runs Claude Code sessions unattended: any skill, any prompt, any project, several at a time. A client pushes a branch and a prompt to the host; a container works in a worktree of that branch; when it ends, the host pushes the branch to GitHub and opens a draft pull request. The client is whatever has git, ssh and rsync: a laptop today, a GitHub Action or a bot tomorrow, since nothing of the result travels back through it. The container is the boundary: it has no key, no Docker socket, no sudo and no published port, so the host can keep serving other things and nothing here touches them.

| File | Does |
| :- | :- |
| `Dockerfile` | the image: Node, pnpm, Chromium, a pinned Claude Code and chrome-devtools MCP, an unprivileged user, git identity and ignore |
| `agent.yml` | the `agent` service every project extends: the mounts, the plugin seed, the stop grace period, the CPU and memory caps |
| `cloud build \| run \| clean` | the client verbs: the image, one run from the current branch, the removal of a run that did not end by itself |
| `test.sh [image]` | the verbs against stubs; with `image`, builds the image and checks the pins |

A project brings one file, `cloud.yml` at its root: the `agent` service plus its sidecars, and the ports its local stack publishes reset (§3.3). `CLAUDE.md` details it.

Why a host and not a Claude Code cloud session: a session that verifies its work needs the app's own database, API and web server plus a browser, and brings them up itself. Why a container and not the box: the box is shared, and a container states exactly what the agent can reach.

## 1. Layout

On the host, one directory that knows nothing about any project, and one directory per project under it:

```
/opt/agent/                              owned by the SSH user
├─ cloud, agent.yml, Dockerfile          rsynced from this repository by every verb
├─ home/                                 the agent's $HOME, shared by every run: the login, plus settings.json, rules/ and skills/ mirrored from the client by every verb
├─ seed/                                 the client's plugins, marketplaces and cache, mirrored by every verb, mounted read-only as CLAUDE_CODE_PLUGIN_SEED_DIR
└─ projects/<project>/
   ├─ env                                the app's configuration, chmod 600, written once by hand
   ├─ cloud.yml                          the project's overlay, rsynced from its root
   ├─ stack.yml                          the project's docker-compose.yml, rsynced, when it has one
   ├─ repo.git                           bare; the client pushes branches to it, the host pushes them on to origin
   ├─ inputs/<branch-slug>/              .claude/ and the file argument, in transit into the worktree
   └─ runs/<branch-slug>/                one worktree per run, absent between runs
      runs/<branch-slug>.prompt, .input  the prompt and the commit the run started from, gone with the run
      runs/<branch-slug>.log             what host-finish printed: the pull request, or why it stopped; kept
```

`<project>` is the origin repository's name, lowercased, with anything but letters and digits replaced by `-`. One run is one Compose project named `<project>-<branch-slug>`, made of the files `stack.yml` then `cloud.yml`:

```
app-feat-x                               network app-feat-x_default, nothing published
├─ agent   cloud session app feat/x             the container's command; launches the session, holds the run
│          └─ claude --bg --remote-control      the session, a plain process in runs/feat-x/
│             ├─ API, web dev server            started by the session from the repository's own instructions
│             └─ Chromium, headless             spawned by the chrome-devtools MCP
└─ postgres                                     from stack.yml, ports reset; up before the session, gone with it
```

The project directory is mounted at its own host path, because `git worktree` records absolute paths and the host removes the worktree from outside the container. The session runs as a process, not as a nested container. The services `docker-compose.yml` declares are the one thing it does not start: they are sidecars, up and healthy before the session, reachable under their service names, and the prompt says so. Everything the session starts binds inside the container's own network namespace, which is why the Claude sandbox stays off: on Linux the sandbox gives every Bash command its own network namespace, so a server started in one command is unreachable from the next and from the browser. The container is the boundary instead.

Runs do not collide: each has its own network, so `postgres:5432` is its own database in every container, and each has its own worktree from the shared bare repository. The shared `home/` is safe the way several terminals on one machine are: one login serves any number of sessions, and session state is keyed by worktree path. The container runs with the SSH user's uid, so the host and the container both own what the run writes. The host's firewall does not change.

## 2. Install (once per host)

```bash
mkdir -p ~/bin && ln -sf "$PWD/cloud" ~/bin/cloud                      # client, from this repository, ~/bin on PATH
ssh vps 'sudo install -d -o $USER -g $USER /opt/agent && install -d -m 700 /opt/agent/home'
ssh vps 'sudo apt install -y gh && gh auth login && gh auth setup-git'  # the token pushes branches and opens pull requests
cloud build                                                            # client: ships the tooling and your Claude setup, builds image `agent` on the host
```

`vps` is the SSH alias of the host; `cloud` reads it from `CLOUD_HOST`, and an empty `CLOUD_HOST` means the Docker daemon of the client itself.

The `gh` login is the host's, outside every container: a fine-grained token limited to the repositories runs may touch, with contents and pull requests write. Protect `main` on those repositories so a token can only ever add a branch. The container never sees it.

Every verb, `build` included, starts by mirroring the client's Claude setup to the host: `~/.claude/settings.json`, `rules/` and `skills/` into `home/.claude/`, and the plugins (`known_marketplaces.json`, `marketplaces/`, `cache/`) into `seed/`, which the container reads as `CLAUDE_CODE_PLUGIN_SEED_DIR`. Which plugins are on comes from `enabledPlugins` in that `settings.json`. A skill or plugin removed on the client leaves the host at the next verb; nothing else under `home/.claude/` is touched, the login in particular. `CLAUDE_CONFIG_DIR` is honoured. The first sync carries the plugin caches, tens of megabytes; later ones carry the difference.

## 3. What only hands can do

1. **Login**, once per host: `ssh -t vps 'cd /opt/agent && docker run --rm -it -v /opt/agent/home:/home/agent agent claude'`, `/login`, copy the URL to a browser, paste the code back. The credentials land in `home/.claude/.credentials.json`, `-rw-------`, and stay there. Never copy this file anywhere. Keep `ANTHROPIC_API_KEY` unset: Remote Control needs the subscription.
2. **The project's configuration**, once per project, on the host: `/opt/agent/projects/<project>/env`, `chmod 600`, one `KEY=value` per line, the app's own variables with each sidecar at its service name. Only dev credentials go in it: nothing that reaches a real bucket, a real database or a real mailbox. No `.env` file exists in the tree, so none can be committed. `cloud run` refuses until the file exists.
3. **The project's overlay**, once per project, in its repository at `cloud.yml`: the `agent` service extending `${AGENT_ROOT}/agent.yml` with `env_file: env` and a `depends_on` per sidecar, and for each service of the repository's `docker-compose.yml` that publishes a port, `ports: !reset []`. The sidecars themselves are never redeclared: `stack.yml` is the repository's own file, and only that name is read (`compose.yaml` is not). A repository without one gets no sidecars and a prompt that says so.
   ```yaml
   services:
     agent:
       extends:
         file: ${AGENT_ROOT}/agent.yml
         service: agent
       env_file: env
       depends_on:
         postgres:
           condition: service_healthy
     postgres:
       ports: !reset []
   ```

## 4. A run

```bash
git switch -c feat/x                      # on main, cloud run asks for a branch name instead
cloud run "Run the implement-loop skill against .claude/deliverable.md"   # a skill
cloud run "Migrate the API tests from Jest to Vitest and make them pass"      # a plain prompt
cloud run .claude/plan.md                 # a file, tracked or ignored: prompt "Implement .claude/plan.md"
```

The tree must be clean: the run starts from the branch as committed, and comes back as commits on it. The client refuses a detached `HEAD`, a missing `origin` and a dirty tree; the host refuses a missing `env`, a missing image, a missing `gh` login, or a container or worktree still holding this branch. Then the client pushes the branch to the host's bare repository, ships everything under `.claude/` except `worktrees/` (briefs, plans and the other inputs of a run, ignored or not) plus the file argument if any, and the host cuts the worktree, drops them in untracked, and starts the Compose project detached, sidecars first. Inside the container, `cloud session` launches `claude --bg --name <project>/<branch> --remote-control <project>/<branch> --permission-mode auto` with the prompt, then polls `claude agents --json --all` every 30 s until the session is neither `working` nor `blocked`; three listings in a row that fail or lack the session end the run with an error.

The last two lines name the session and what comes back: **Code → `<project>/<branch>`** in the Claude app is where the run is watched, answered and, if needed, stopped. There is no status, attach or stop verb.

The prompt the session gets is yours, preceded by three lines: this is a run of the project in its own container and the app's configuration is in the environment; the services `docker-compose.yml` declares are already up under their names, so do not start Docker; bring the rest of the stack up from the repository's own instructions inside this worktree, and stop what you started; commit your work on this branch as you go, with real messages, and do not push.

## 5. The end

Nothing to do on the client. `host-finish`, left waiting on the container by `cloud run`, wakes when the container exits, for any reason: the session ended, was stopped in the app, or the container was stopped (`docker stop`, or the Compose project going down: `cloud session` stops the session within the two-minute grace period). It commits whatever the session left uncommitted as `run: <branch>`, pushes the branch to origin, opens a draft pull request titled with the prompt's first line and bodied with the prompt, or reuses the pull request already open on that branch, and removes the run from the host: the container, the Compose project with its volumes, the worktree. A run that changed nothing pushes nothing and opens nothing. The log at `runs/<branch-slug>.log` says which.

On the client, the branch is then any other branch: `git pull`, review the pull request, mark it ready. `.claude/` travels one way: what the run wrote there does not come back. Branch protection on `main` is what keeps a run's token to branches.

```bash
cloud clean      # a run host-finish could not end (its log says why), or one you abandon: same refusals, repeatable
```

`host-finish` stops before the cleanup when the push or the pull request fails: the commit is safe on the host's `repo.git`, the worktree stays, the log has the error. Fix the cause (usually the token), then `cloud clean`; the branch on `repo.git` keeps the commit, `git fetch vps:/opt/agent/projects/<project>/repo.git <branch>` gets it by hand.

## 6. Looking at the host

```bash
ssh vps 'docker ps -a --format "{{.Names}}\t{{.Status}}"; ls /opt/agent/projects/*/runs'   # every run, going or finished
ssh vps 'cat /opt/agent/projects/<project>/runs/<slug>.log'                                 # how the run ended: the pull request, or the error
ssh vps 'docker logs <project>-<slug> | tail -50'                                            # what cloud session printed: the id
ssh vps 'ls -la /opt/agent/projects/<project>/runs/<slug>/.claude'                          # a skill's own progress file, when it keeps one
ssh vps 'docker exec <project>-<slug> claude logs <id> | cat -v | tail -40'                 # the session's screen
```

A worktree present with its container exited and no pull request in the log is a run whose `host-finish` died with the host (a reboot): `cloud clean` if its tree is clean, otherwise commit or discard on the host first.

## 7. Upgrading

- **Claude Code, pnpm, the MCP**: change the `ARG` in the `Dockerfile`, `bash test.sh image` on the client, `cloud build`, then one probe run on a scratch branch: `cloud run "Bring the stack up, open the web app in Chrome through the chrome-devtools MCP, report document.title, then stop everything you started"`. That run is the only test of the Compose network, Chromium, Remote Control, the plugin seed and the workspace trust on the real host. `cloud session` reads `backgrounded · <id>` and the `working`/`blocked` states from the CLI; a session that never appears in `claude agents --all`, or a listing that stops parsing, ends the run with an error after three polls, so a changed CLI fails loudly rather than reporting no changes.
- **The tooling and the client's Claude setup**: nothing to do; every verb ships both. Every session start also turns the sandbox off in the mirrored `settings.json` and registers the chrome-devtools MCP with the image's Chromium, whatever the copy says.
- **Rotate the logins**: `/logout` then `/login` in step 3.1, and `gh auth refresh` or a new token on the host, twice a year, and after any doubt about the box.

## 8. What the container has and what it never has

Has: the image, `home/` with the login, the mirrored settings, rules and skills, the plugin seed read-only, its project's directory with the bare repository and `env`, outbound network. Never has: a key or token of any kind, a way to push anywhere (the host pushes, from outside), another project's directory, the Docker socket, sudo, a published port, a real credential, the client's `~/.claude.json` session state.

The container is also what makes the setup portable: the same files run on any machine with Docker, the client itself included, with `CLOUD_HOST` empty and `AGENT_ROOT` pointing at a directory Docker Desktop can share. The image installs Debian's Chromium, which exists for arm64, and a second login lives in that machine's `home/`.
