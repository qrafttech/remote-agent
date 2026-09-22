# Remote agent host

A GitHub Actions workflow runs a Claude Code session on a self-hosted runner, in a container from this repository's image, on the branch it is dispatched with; the session pushes and opens pull requests itself, a stack included, and the job pushes whatever it left as a draft pull request.

## What a project brings

One file, `.github/workflows/cloud.yml`, copied from `workflow.yml` here, plus the repository secrets it names. Nothing else in the project exists for the runner's sake: the job brings `docker-compose.yml` up as is, and the session brings the rest of the stack up from the project's own README and `CLAUDE.md`.

### `.github/workflows/cloud.yml`

The template as is, with one block edited:

- `env:` of the job: the keys of the project's `.env.example` files, each service of `docker-compose.yml` at its service name (`postgres:5432`, not `localhost`), the app's own servers at `localhost`. Dev values are written in the file, as CI writes them; a value that must not be in the tree is a repository secret, `gh secret set NAME`, read as `${{ secrets.NAME }}`. Dev credentials only: nothing that reaches a real bucket, a real database or a real mailbox.

Everything else stays: `permissions`, `concurrency`, `timeout-minutes`, the checkout without credentials, the session step (Compose up from `docker-compose.yml` with its ports reset, then `docker run` of the agent image on that network), the last step. The sidecars are never retyped: the step reads `docker-compose.yml` as is, and a project without one skips Compose and gets a prompt that says to bring the whole stack up.

### What the run reads from the project

- The branch as pushed to GitHub: the result comes back as commits on it, and as the pull requests the session opened — a stack included — plus a draft on the branch for anything it left unpushed. What is not pushed does not travel: an ignored brief goes in the prompt, `-f prompt="$(cat plan.md)"`.
- The token, `CLOUD_TOKEN` of README §3.5: a fine-grained personal access token on the project's repository, *Contents* and *Pull requests* read and write. It is `GH_TOKEN` in the container and in the last step. Absent, `github.token` takes its place and everything still works, except that nothing the run pushes or opens triggers another workflow — no CI on its pull requests.
- The prompt, from `gh workflow run cloud --ref <branch> -f prompt="…"`, or the `/cloud` skill on the client. Absent, `Continue where you left off.` — the input is optional because a run can be a session's next turn: a session already named `<repo>/<branch>` on the host is resumed with the prompt, unless `-f fresh=true`.
- The repository settings of README §3.4: Actions may create pull requests; `main` protected.

## Rules of this repository

- One script, `session`, one job: the step that launches and holds the session. What happens before it (checkout, sidecars) and after it (commit, push, pull request) is the workflow's, in `workflow.yml`, in plain `run:` steps. What happens on the client before the dispatch (refuse a dirty tree, the host's login, the sessions it holds, push, dispatch, watch, report) is the `/cloud` skill's, `skills/cloud/SKILL.md`, written as literal shell with its two judgment points marked. A behaviour goes in the one of the three that owns it, not in a new file.
- `test.sh` is the specification of `session`. A behaviour change adds or changes a `check` line first; the `claude` stub grows only what a check needs. `bash test.sh` must pass before a push; `bash test.sh image` after any change to the `Dockerfile`; `image.yml` runs both before it pushes the image.
- `session` carries a short header (what it is) and a comment above each helper saying what it is for. `workflow.yml` carries one comment above the block a project edits. No other comments: what a line does is said by the line, and what a reader would get wrong goes in the README.

## Anatomy of a run

One run is one job on one runner, as the runner's user, one Compose project per job named `cloud-<run id>`:

```
job                                          steps on the host
├─ docker compose up -d --wait                  the project's docker-compose.yml as is, ports unpublished; skipped when the project has none
├─ docker run … agent session …                 ghcr.io/qrafttech/agent on the job's network
│  └─ session <repo>/<branch> "<prompt>" [fresh] the container's process, behind docker-init; resumes or launches the session, holds the step
│     └─ claude --bg [--resume] --remote-control the session, a plain process in the checkout
│        ├─ API, web dev server                 started by the session from the repository's own instructions
│        └─ Chromium, headless                  spawned by the chrome-devtools MCP
└─ docker compose down -v · commit · push · PR  the last step, on the host, always
```

- **Checkout**: `actions/checkout` with `persist-credentials: false` — the checkout keeps no token; the container's `git` gets one from `gh auth git-credential` (`credential.helper` of the image) and `gh` from `GH_TOKEN`.
- **Sidecars**: if `docker-compose.yml` exists, the job generates an override from `docker compose config --services` that resets every `ports:` (`{ports: !reset []}`, Compose ≥ 2.24), then `docker compose -p cloud-<run id> up -d --wait`. The network is `cloud-<run id>_default`. No file, no Compose, no sidecar.
- **The agent container**: `docker run --rm --init --pull always --name cloud-<run id>`, on the job's network if there is one. It mounts `/opt/agent/home` at `/home/agent` and the checkout's **parent** directory at its host path, working directory the checkout. The job's `env:` is passed key by key (`jq` over `toJSON(env)`, with `PROMPT`, `FRESH`, `CONFIG` and `GH_TOKEN` deleted — the prompt is not in the container's environment), then `GH_TOKEN` on its own. Nothing else crosses.
- **Why the parent directory**: pnpm keeps a store at the top of its mount. Mounted at the checkout, that store lands inside it — a probe committed `.pnpm-store/`, 83,410 files. At the parent, it sits next to the checkout, on the host, kept between runs.

Runs do not collide: each job has its own Compose project, network, volumes and checkout, so `postgres:5432` is its own database in every container. The shared `home/` is safe the way several terminals on one machine are: one login serves any number of sessions, and session state is keyed by checkout path, the same on every run of a runner. That key is also the limit of a resume: a session, and whatever a skill keeps in the checkout's `.git/` between runs, belong to one runner's checkout, and a branch is not pinned to a runner. With several runners per repository a run resumes only when the same runner picks it; otherwise it starts new and says so. One runner per repository is the setting in which every run on a branch is the previous one's next turn. The container runs as uid 1000, the runner's user, so host and container both own what a run writes. The same branch queues behind itself (`concurrency: cloud-<ref>`); different branches run in parallel.

## The session step (`session`)

`session <name> <prompt> [fresh]` is the only thing that runs in the container. In order:

1. **Adapt the mirrored setup** (every start, since the sync of README §3.2 restores the client's copy):
   - `settings.json`: `sandbox.enabled` forced to `false`, `hooks` and `statusLine` deleted (they name commands of the client, absent here). Everything else applies as on the client, `permissions.ask` included.
   - `plugins/known_marketplaces.json` and `plugins/installed_plugins.json`: every absolute `…/.claude/plugins/` path rewritten to this home's.
   - The chrome-devtools MCP registered (`claude mcp add --scope user … --executablePath /usr/local/bin/chromium`) unless already present.
   - `~/.local/share/gh/extensions` linked to `/opt/gh/extensions` of the image, where `gh stack` is baked at its pinned version, unless something is already there. That directory is root's: `gh extension install` and `upgrade` are refused in the container; the image's set is the set.
2. **Core dumps off** (`ulimit -c 0`): a crashing child must leave nothing for the last step's `git add -A`.
3. **Login check**: `claude auth status --json` must report `loggedIn: true`; otherwise the step fails with `not logged in` before any launch. A session launched without a login only says `Login expired`, is listed `blocked`, and would hold the job for its whole timeout.
4. **Resume or launch**: unless the third argument is `fresh`, `claude agents --json --all` is searched for sessions named `<name>` whose `cwd` is this checkout and whose status is neither `running` nor `busy` (the CLI's word for a turn in flight, seen on the real host); the newest by `startedAt` gives `--resume <sessionId>`. A session of another checkout — another runner's — has its transcript there, not here, so a run picked up by the other runner starts a new session and says so; a running one would only be copied by `--resume`, so it is skipped. Then `claude --bg [--resume <sessionId>] --name <name> --remote-control <name> --permission-mode auto` with the composed prompt: a resumed session continues under its same ID with the prompt as its next turn, a new one starts. The id is read from the CLI's `backgrounded · <id>` line; if none appears, the step fails with `no session id`.
5. **Poll** `claude agents --json --all` every 30 s (env `POLL` overrides). The **state** is the session's own word (`working`, `blocked`, `done`, …); the **status** is the CLI's (`running`, `idle`).
6. **On any exit**, SIGTERM included: stop the session if it is still going (`claude stop`). Never `claude rm`: the session stays listed on the host, for the next run of the branch to resume and for the app to show. Committing what it left is the workflow's job.

The prompt is the user's, preceded by four lines:

> This is a run of `<repo>` in its own container, and the app's configuration is in your environment.
> The services docker-compose.yml declares are already up under their service names, so do not start Docker; bring the rest of the stack up, from the repository's own instructions, inside this checkout, through one subagent rather than in your own turns: it installs, migrates, seeds and starts the servers detached so they outlive it (setsid nohup, output to a log file), and hands back only the addresses, how to sign in and where the logs are; the install output, the retries and the errors stay in its context, not yours. Stop what you started before you finish.
> Commit your work on this branch as you go, with real messages. GH_TOKEN in your environment is a token on this repository: push and open pull requests yourself, as drafts, when the task calls for it (a stack of branches with gh stack); whatever is left unpushed when you finish, the workflow pushes as a draft pull request on the branch you leave checked out.
> These lines address the session alone: a subagent that reads them does the one task it was handed and neither runs a skill, commits nor pushes.

A repository without `docker-compose.yml` gets "Bring the whole stack up" in place of the second line's first clause. The bring-up goes through a subagent because it is the session's largest single spend: on a measured run the session took 98 of its first 152 turns to install, migrate, seed, start the servers and sign in — 11M of the 18.7M input tokens it read — and every one of those turns re-read the whole context. A subagent spends the same turns on a context of its own and returns one report; the servers must be detached (`setsid nohup`) or they die with its shell.

### States, and what ends the step

| Observation | Meaning | Outcome |
| :- | :- | :- |
| `working` (status `running`) | the session is going | keep polling |
| `blocked` | the session asked a question; it is answered in the app | keep polling — a run can hold its runner until `timeout-minutes` |
| `working` + status `idle`, three polls in a row (90 s) | the turn is over without a `done`: the state is the session's own word and it can end without changing it | `session <id> idle, working by its own account`, exit 0 |
| any other state (`done`, `stopped`, …) | the session ended | `session <id> <state>`, exit 0 |
| missing from the listing, or the listing fails, three polls in a row | the session or the CLI is gone | `session <id> is missing|error for claude agents --all, three times in a row`, exit 1 |

One occurrence of missing/error resets on the next good listing; so does one idle poll on the next `running`.

### Every message `session` prints

- `usage: session <name> <prompt> [fresh]` — wrong arity, or a third argument other than `fresh`, exit 1.
- `not logged in: <home>/.claude holds no valid login; log in on the host, README §3.1` — `claude auth status` reports no login, exit 1, nothing launched.
- `no session id` — `claude --bg` produced no `backgrounded · <id>` line, exit 1.
- `session <id> running as <name>` — the launch line; `session <id> resumed from <sessionId>, running as <name>` when a session of that name was resumed.
- `session <id> <state>` — the session ended with that state, exit 0.
- `session <id> idle, working by its own account` — the idle rule above, exit 0.
- `session <id> is missing|error for claude agents --all, three times in a row` — exit 1.

## The last step

Runs `if: always()` — after a session that ended, was stopped in the app, cancelled or timed out:

1. `docker rm -f cloud-<run id>` — removes the agent container if a cancel left it.
2. `docker compose -p cloud-<run id> down -v` — sidecars and volumes gone (skipped without a compose file).
3. `git add -A` excluding `*.log`, `*.tmp`, `*.pid`; if anything is staged, commit as `run: <branch>` (author `agent <agent@cloud>`). `<branch>` is the one left checked out — the dispatched branch, or another when the session moved (`gh stack add` checks the new branch out); a detached `HEAD` counts as the dispatched branch.
4. If `HEAD` did not move: print `no changes on <branch>` and stop — no push, no pull request.
5. Push `<branch>` with the same token (`gh auth git-credential`), on the host, after the container is gone — a no-op when the session pushed it already.
6. Open a draft pull request titled with the prompt's first line (cut to 72 characters), bodied with the prompt — unless one is already open on the branch, the session's own included, which is left alone. Pull requests the session opened on other branches (a stack) are not in the log; the `/cloud` skill lists them by date.

Cancelling: stopping the session in the Claude app is the soft way — the poll sees it end within 30 s. `gh run cancel` is the hard way: the runner signals the step, `docker run --init` forwards SIGTERM to `session`, whose trap stops the Claude session (exit 143) and leaves it listed; the last step still commits and pushes. Either way the next run on the branch resumes that session. `timeout-minutes` is 1380 (23 h) because `github.token`, the fallback, lives 24 at most.

## What the container has and never has

Has: the image, `home/` with the login and the mirrored setup, the checkout of one branch, the sidecars on the job's network, the app's configuration in the environment, outbound network, and `GH_TOKEN` — the one token, scoped to the project's repository, so the session can push any branch of it (`main` is protected, README §3.4) and open pull requests. It is in the environment of every process the session starts, dependencies' install scripts included; the token's scope is the boundary, not the container. Nothing writes it to the tree or the log: `-e GH_TOKEN` passes no value on the command line, Actions masks it, and `gh auth login` refuses while it is set, so nothing lands in the shared `home/`.

Never has: another repository, sudo, a published port, a real credential, the client's `~/.claude.json`, the host's Docker socket.

What does have Docker is the runner's user, and so the steps of `cloud.yml` on the dispatched branch: a session can edit that file, so read the diff of `.github/` in the pull request before dispatching the branch again. Pushing such an edit takes the token's *Workflows* permission (README §3.5); without it the push is refused and the commit stays in the runner's checkout.

## Why it is built this way

- **A host, not a Claude Code cloud session**: a session that verifies its work needs the app's database, API, web server and a browser, and brings them up itself.
- **GitHub Actions, not a script**: the runner, the checkout, the secrets, the queue, the logs, the token that pushes and the cancel button exist already; what is left is one step.
- **`docker compose up` + `docker run`, not the runner's `container:`/`services:`**: the runner would mount the host's Docker socket into the session's container, unconditionally, and would need every sidecar retyped. This way the session gets a container with nothing of the host in it, and the project's `docker-compose.yml` is read as is.
- **Claude sandbox off**: on Linux it gives every Bash command its own network namespace, so a server started in one command is unreachable from the next. The container is the boundary instead.
- **The stack brought up by a subagent, not the session**: install, migrations, seeding and sign-in are dozens of short retry-prone turns, and a session's turns each re-read its whole context. Delegated, they cost one turn of the session's; the session keeps the addresses and the log paths, which is all it needs of them.

## What the probes proved, and what is left

Probe runs (`Bring the stack up, open the web app in Chrome, report document.title, then stop`) settle what the stubs cannot:

- `docker run --pull always` pulls the image; a public package needs no login. The checkout, written by the runner's uid 1000, is writable by the image's user; `HOME` stays `/home/agent`, where the login is mounted. The mirrored plugins load with `enabledPlugins` from the mirrored `settings.json`.
- The session runs `pnpm install`, the migrations, the API and the web dev server as processes, and headless Chromium renders the app via the MCP. A `.env` it tries to write may be denied; the environment is authoritative and it falls back to it.
- `docker compose up --wait` with the `!reset` override works on Compose v5, Postgres healthy in 6 s; `toJSON(env)` is the job's `env:` and nothing else, so the prompt is not in the container's environment; the last step takes the project down, commits, pushes and opens the pull request from the host.
- With the checkout alone mounted, a run committed `.pnpm-store/` (hence the parent-directory mount); with the parent mounted, the next probe printed `no changes on probe` — no pull request, no container, volume or network left. The session was listed under Code in the Claude app while it ran.
- `gh run cancel` a minute in: the step ended within 3 s and the session was stopped — `session`'s trap at work, and what a killed container would not do. (At the time the trap also removed the session; it no longer does, so the listing keeps it.)
- With `home/.claude/` shipped from git as in README §3.2, the probe went green: `session … done` after 2.5 min; `session` had adapted the fresh copy, sandbox off and registries on the container's paths.
- One probe answered in 2 min 20 s and never declared `done`: its `state.json` kept `working` while the CLI listed it `status: idle` with nothing in flight. Polling the state alone would have held the job for its 1380 minutes — hence the idle rule.
- The same template, prompt and last step served a project of the other shape — no Postgres sidecar, an embedded SQLite-style store — with no edit. Its `docker-compose.yml` declared the app itself, which the job had already brought up; the session left it alone, brought the rest up itself, verified in Chromium, stopped its servers, and its one real commit came back as a draft pull request. So the only thing that changes between project shapes is what `docker-compose.yml` declares; the template, the prompt and the last step do not.

- `claude agents --json --all` from a `docker run` outside the job lists the job's live session as `failed`: the state file says `working` and the process is in another container. Only the job's own container sees `working`/`busy`. The `/cloud` skill's listing is that outside view, so `failed` on a branch whose run is in progress means live, not dead.
- A run that paused an implement loop at round 3 ended its turn with `done`; `session` then removed the session, so the resume it had scheduled for itself never fired, and only the transcript survived. Hence: sessions are kept, and a run on a branch that has one is its next turn.

Left: a `blocked` session answered from the app — the sessions were watched there, none was asked a question. A resumed session on the real host: `claude --bg --resume` is in the pinned CLI's help, and the stub proves the call, but the probe of a second run on a branch that has a session is not made yet.
