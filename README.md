# Remote agent host

A machine with Docker runs Claude Code sessions unattended: any skill, any prompt, any project, several at a time. The Mac pushes a snapshot of its branch and a prompt to the host; a container works in a worktree and commits what it did; the Mac fetches the result and applies it back. The container is the boundary: it has no key, no Docker socket, no sudo and no published port, so the host can keep serving other things and nothing here touches them. This page is what runs where and what to expect.

| File | Does |
| :- | :- |
| `Dockerfile` | the image: Node, pnpm, Chromium, a pinned Claude Code and chrome-devtools MCP, an unprivileged user, git identity and ignore |
| `agent.yml` | the `agent` service every project extends: the mounts, the plugin seed, the stop grace period, the CPU and memory caps |
| `cloud build \| run \| pull \| clean` | on the Mac: the image, one run from the current branch, its return, its cleanup |
| `test.sh [image]` | the Mac verbs against stubs; with `image`, builds the image and checks the pins |

A project brings one file, `cloud.yml` at its root: the `agent` service plus its sidecars, and the ports its local stack publishes reset (§3.3).

Why a host and not a Claude Code cloud session: a session that verifies its work needs the app's own database, API and web server plus a browser, and brings them up itself. Why a container and not the box: the box is shared, and a container states exactly what the agent can reach.

## 1. Layout

On the host, one directory that knows nothing about any project, and one directory per project under it:

```
/opt/agent/                              owned by the SSH user
├─ cloud, agent.yml, Dockerfile          rsynced from this repository by every cloud verb
├─ home/                                 the agent's $HOME, shared by every run: the login, plus settings.json, rules/ and skills/ mirrored from the Mac by every verb
├─ seed/                                 the Mac's plugins, marketplaces and cache, mirrored by every verb, mounted read-only as CLAUDE_CODE_PLUGIN_SEED_DIR
└─ projects/<project>/
   ├─ env                                the app's configuration, chmod 600, written once by hand
   ├─ cloud.yml                          the project's overlay, rsynced from its root
   ├─ stack.yml                          the project's docker-compose.yml, rsynced, when it has one
   ├─ repo.git                           bare; the Mac pushes to it and fetches from it over SSH
   └─ runs/<branch-slug>/                one worktree per run, absent between runs
```

`<project>` is the origin repository's name, lowercased, with anything but letters and digits replaced by `-`. One run is one Compose project named `<project>-<branch-slug>`, made of the files `stack.yml` then `cloud.yml`:

```
app-feat-x                               network app-feat-x_default, nothing published
├─ agent   cloud session app feat/x             the container's command; cuts the worktree, holds the run, commits
│          └─ claude --bg --remote-control      the session, a plain process in runs/feat-x/
│             ├─ API, web dev server            started by the session from the repository's own instructions
│             └─ Chromium, headless             spawned by the chrome-devtools MCP
└─ postgres                                     from stack.yml, ports reset; up before the session, gone with it
```

The project directory is mounted at its own host path, because `git worktree` records absolute paths and `host-clean` removes the worktree from outside the container. The session runs as a process, not as a nested container. The services `docker-compose.yml` declares are the one thing it does not start: they are sidecars, up and healthy before the session, reachable under their service names, and the prompt says so. Everything the session starts binds inside the container's own network namespace, which is why the Claude sandbox stays off: on Linux the sandbox gives every Bash command its own network namespace, so a server started in one command is unreachable from the next and from the browser. The container is the boundary instead.

Runs do not collide: each has its own network, so `postgres:5432` is its own database in every container, and each has its own worktree from the shared bare repository. The shared `home/` is safe the way several terminals on one Mac are: one login serves any number of sessions, and session state is keyed by worktree path. The container runs with the SSH user's uid, so the host and the container both own what the run writes. The host's firewall does not change.

## 2. Install (once per host)

```bash
mkdir -p ~/bin && ln -sf "$PWD/cloud" ~/bin/cloud                      # Mac, from this repository, ~/bin on PATH
ssh vps 'sudo install -d -o $USER -g $USER /opt/agent && install -d -m 700 /opt/agent/home'
cloud build                                                            # Mac: ships the tooling and your Claude setup, builds image `agent` on the host
```

`vps` is the SSH alias of the host; `cloud` reads it from `CLOUD_HOST`, and an empty `CLOUD_HOST` means the Docker daemon of the Mac itself.

Every verb, `build` included, starts by mirroring the Mac's Claude setup to the host: `~/.claude/settings.json`, `rules/` and `skills/` into `home/.claude/`, and the plugins (`known_marketplaces.json`, `marketplaces/`, `cache/`) into `seed/`, which the container reads as `CLAUDE_CODE_PLUGIN_SEED_DIR`. Which plugins are on comes from `enabledPlugins` in that `settings.json`. A skill or plugin removed on the Mac leaves the host at the next verb; nothing else under `home/.claude/` is touched, the login in particular. `CLAUDE_CONFIG_DIR` is honoured. The first sync carries the plugin caches, tens of megabytes; later ones carry the difference.

## 3. What only hands can do

1. **Login**, once per host: `ssh -t vps 'cd /opt/agent && docker run --rm -it -v /opt/agent/home:/home/agent agent claude'`, `/login`, copy the URL to the Mac's browser, paste the code back. The credentials land in `home/.claude/.credentials.json`, `-rw-------`, and stay there. Never copy this file anywhere. Keep `ANTHROPIC_API_KEY` unset: Remote Control needs the subscription.
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

In order. The Mac refuses a detached `HEAD`, a missing `origin` and a run of this branch already out (`cloud pull` first). It ships the tooling and the overlay, and the host refuses a missing `env`, a missing image, or a container or worktree still holding this branch. Then the Mac builds one commit from the working tree as it stands, tracked and untracked, plus everything under `.claude/` except `worktrees/` (where briefs, plans and the other inputs of a run live), the file argument if any, and `.claude/prompt.txt`, without touching the branch or its index, pushes that commit to the host's bare repository as `run/<branch>` and remembers it as `refs/cloud/<branch>`. The host starts the Compose project detached, sidecars first; inside the container, `cloud session` cuts the worktree on `run/<branch>` and launches `claude --bg --name <project>/<branch> --remote-control <project>/<branch> --permission-mode auto` with the prompt, then polls `claude agents --json --all` every 30 s until the session is neither `working` nor `blocked`; three listings in a row that fail or lack the session end the run with an error.

The last two lines name the branch and the session: **Code → `<project>/<branch>`** in the Claude app is where the run is watched, answered and, if needed, stopped. There is no status, attach or stop verb.

The prompt the session gets is yours, preceded by two lines: this is a run of the project in its own container and the app's configuration is in the environment; the services `docker-compose.yml` declares are already up under their names, so do not start Docker; bring the rest of the stack up from the repository's own instructions inside this worktree, and stop what you started.

## 5. The return

```bash
cloud pull
```

Refuses a dirty tree, a run still going, and a worktree holding uncommitted work (a run killed harder than `docker stop`: commit or discard it on the host). Otherwise it cleans the host first (the container, the Compose project with its volumes, the worktree), fetches `run/<branch>` from the bare repository and applies the difference between the snapshot it sent and what came back as a three-way patch, leaving the delta **staged and uncommitted** on the branch, exactly where a local session would have left it. Committing on the branch during the run is fine: the patch is three-way and `pull` says when the branch moved; a hunk it cannot merge is left with conflict markers, the refs kept: resolve, then `cloud clean`. `.claude/` travels one way: what the run wrote there does not come back. A run that changed nothing is reported as such. Last, `run/<branch>` on the host and the local ref are deleted.

`cloud session` had already, on its own exit: stopped and removed the session, and committed the tree as `run: <branch>` on `run/<branch>`, which the worktree has checked out, so there is nothing to push. Stopping the container (`docker stop`, or the Compose project going down) sends the same exit: the session is stopped and what exists is committed, within the two-minute grace period.

```bash
cloud clean      # a run you abandon, or a pull whose host cleanup failed: same cleanup, same refusals, repeatable
```

## 6. Looking at the host

```bash
ssh vps 'docker ps -a --format "{{.Names}}\t{{.Status}}"; ls /opt/agent/projects/*/runs'   # every run, going or finished
ssh vps 'docker logs <project>-<slug> | tail -50'                                            # what cloud session printed: the id, the commit
ssh vps 'ls -la /opt/agent/projects/<project>/runs/<slug>/.claude'                          # a skill's own progress file, when it keeps one
ssh vps 'docker exec <project>-<slug> claude logs <id> | cat -v | tail -40'                 # the session's screen
```

A worktree present with its container exited is a finished run waiting for its `cloud pull`.

## 7. Upgrading

- **Claude Code, pnpm, the MCP**: change the `ARG` in the `Dockerfile`, `bash test.sh image` on the Mac, `cloud build`, then one probe run on a scratch branch and `cloud pull`: `cloud run "Bring the stack up, open the web app in Chrome through the chrome-devtools MCP, report document.title, then stop everything you started"`. That run is the only test of the Compose network, Chromium, Remote Control and the workspace trust on the real host. `cloud session` reads `backgrounded · <id>` and the `working`/`blocked` states from the CLI; a session that never appears in `claude agents --all`, or a listing that stops parsing, ends the run with an error after three polls, so a changed CLI fails loudly rather than reporting no changes.
- **The tooling**: nothing to do; every verb ships it.
- **The Mac's Claude setup**: nothing to do; every verb mirrors it. Every session start also turns the sandbox off in the mirrored `settings.json` and registers the chrome-devtools MCP with the image's Chromium, whatever the copy says.
- **Rotate the login**: `/logout` then `/login` in step 3.1, twice a year, and after any doubt about the box.

## 8. What the container has and what it never has

Has: the image, `home/` with the login, the copied settings and the pnpm store, its project's directory with the bare repository and `env`, outbound network. Never has: a key of any kind, a way to push anywhere but the bare repository the Mac fetches from, another project's directory, the Docker socket, sudo, a published port, a real credential, the Mac's `~/.claude.json` session state, or a `.env` inside any commit.

The container is also what makes the setup portable: the same files run on any machine with Docker, the Mac included, with `CLOUD_HOST` empty and `AGENT_ROOT` pointing at a directory Docker Desktop can share. The image installs Debian's Chromium, which exists for arm64, and a second login lives in that machine's `home/`.
