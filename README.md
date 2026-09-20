# Remote agent host

A machine with Docker runs Claude Code sessions unattended — any project, any prompt, several at a time. You dispatch a project's `cloud` workflow with a branch and a prompt. A self-hosted runner brings the project's `docker-compose.yml` up, runs the session in a container from this repository's image; the session pushes and opens pull requests itself — a stack of them with `gh stack` — and whatever it leaves unpushed, the job pushes as a draft pull request. Nothing runs in GitHub's cloud. The container holds one token, scoped to the project's repository (§3.5), and no sudo, no published port, no Docker socket.

![Architecture: triggers, GitHub, the VPS with two runners, and the Claude app](docs/architecture.svg)

The trigger is anything with `gh`. The session is a plain process on the checked-out branch: it starts the app's servers itself and checks its work in headless Chromium (chrome-devtools MCP). Watch, answer or stop it from the Claude app over Remote Control. The same branch queues behind itself; different branches run in parallel.

| File | Does |
| :- | :- |
| `Dockerfile` | the image: Node, pnpm, Chromium, pinned Claude Code, MCP, `gh` and `gh stack`, `session` |
| `session` | the run's one step in the container: adapt the setup, resume the branch's session or launch `claude --bg`, poll until it ends |
| `workflow.yml` | the template a project copies to `.github/workflows/cloud.yml` |
| `.github/workflows/image.yml` | builds and tests the image on every push to `main`, pushes `ghcr.io/qrafttech/agent` |
| `test.sh [image]` | `session` against a stubbed `claude`; with `image`, builds and checks the pins |
| `AGENTS.md` | what a project brings, the rules of this repository, and the reference: every step, state, message |
| `skills/cloud/` | the `/cloud` skill: push, dispatch, watch, report — from a Claude session on the client |
| `docs/` | the two figures |

## 1. Layout

One host user, `agent`, uid 1000, in the `docker` group — the one you ssh as; `vps` below is your ssh alias for the host, the one the `/cloud` skill uses too. It owns:

```
/opt/agent/home/       the agent's $HOME in every container: the login, your ~/.claude at HEAD, its plugins/
~/runner-<repo>-<n>/   one Actions runner per concurrent run, per repository; a systemd service
```

Each job gets its own network, sidecars and checkout. Only `home/` and the runners are shared. A run resumes the branch's session only from the runner whose checkout started it (`AGENTS.md`, "Anatomy of a run"): one runner per repository if every run is to be the previous one's next turn.

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

1. **Login**, once per host, then every 30 days: `ssh -t agent@vps 'docker run --rm -it -v /opt/agent/home:/home/agent ghcr.io/qrafttech/agent claude auth login'`, the URL in a browser, the code back. Verify: the same `docker run` without `-it`, `claude auth status`, must say `"loggedIn": true`. Credentials stay in `home/.claude/.credentials.json`; never copy that file. The refresh grant is capped at 30 days from the login; past it the file is emptied and a job dies at once with `not logged in`. Keep `ANTHROPIC_API_KEY` unset and never use `claude setup-token`: Remote Control needs the subscription login, and a setup-token cannot open one.
2. **Your Claude setup**, at every change. Commit first — only the committed tree travels. The `/cloud` skill is part of it: `ln -s ~/code/remote-agent/skills/cloud ~/.claude/skills/cloud`, committed as a link (it dangles on the host, where nothing dispatches):
   ```bash
   git -C ~/.claude archive HEAD | ssh agent@vps "cd /opt/agent/home/.claude && rm -rf $(git -C ~/.claude ls-tree --name-only HEAD | xargs) && tar x"
   rsync -a --delete ~/.claude/plugins/ agent@vps:/opt/agent/home/.claude/plugins/
   ```
   Never edit the copy by hand; every session start adapts it (see `AGENTS.md`).
3. **The project's workflow**, once per project. Copy `workflow.yml` to `.github/workflows/cloud.yml`. Fill `env:` with the keys of the project's `.env.example` files: compose services at their service name (`postgres:5432`, not `localhost`), the app's own servers at `localhost`. Dev values go in the file; anything sensitive is a repository secret (`gh secret set NAME`, read as `${{ secrets.NAME }}`). Dev credentials only. The workflow must be on `main` and on the branch it runs.
4. **Repository settings**, once per project: allow Actions to create pull requests (Settings → Actions → General); protect `main`.
5. **The token**, once per project: a fine-grained personal access token (Settings → Developer settings → Fine-grained tokens) on that one repository, permissions *Contents*, *Pull requests* and *Workflows*, each read and write, nothing else (Workflows because a push that touches `.github/workflows/` — a session editing `cloud.yml` — is refused without it); `gh secret set CLOUD_TOKEN`, or `pbpaste | gh secret set CLOUD_TOKEN --repo owner/repo` from the clipboard. The session pushes and opens pull requests with it, and so does the last step. It is `GH_TOKEN` in the container's environment, so every process the session starts inherits it — `pnpm install` and its scripts, the API, the dev server, Chromium; the scope of the token and the protection of `main` are what bound that. Without the secret the workflow falls back to `github.token`, which works the same with one difference: what it pushes or opens triggers no other workflow, so the project's CI never runs on the run's pull requests. Renew the token when it expires (a year at most); a run then fails at its first push.

## 4. A run

![A run in six steps: push and dispatch, queue, checkout and containers up, session, teardown and push and draft pull request, review](docs/run.svg)

```bash
gh workflow run cloud --ref feat/x -f prompt="Run the implement-loop skill against .claude/deliverable.md"
gh workflow run cloud --ref feat/x -f prompt="$(cat plan.md)"    # a file as the prompt
gh workflow run cloud --ref feat/x -f fresh=false                  # resume the branch's session: "Continue where you left off." (without any -f, gh asks interactively)
gh workflow run cloud --ref feat/x -f fresh=true -f prompt="…"     # a new session although one is named after the branch
```

Or, from a Claude session in the project's checkout, `/cloud <prompt>` — the `cloud` skill of this repository (`skills/cloud`, linked into `~/.claude/skills/`). It refuses a dirty tree (what is not pushed does not travel), checks the host's login, lists the sessions the host already holds for this branch, pushes, dispatches, watches the run and reports the pull request. On `main` it pushes HEAD to a new `cloud/<date>-<slug>` branch; on any other branch, the run continues that branch.

**Sessions are kept.** A run never removes its session: it stays listed on the host and in the Claude app, and the next run on the same branch resumes it — same ID, same context — with the new prompt as its next turn. `/cloud fresh <prompt>` (or `-f fresh=true`) starts a new one instead, leaving the old one listed; a resumed session re-reads its whole transcript first, so that is the choice for a long one. No prompt at all means `Continue where you left off.` To forget a session: `ssh agent@vps 'docker run --rm -v /opt/agent/home:/home/agent ghcr.io/qrafttech/agent claude rm <id>'`, by hand, never by the tooling.

The session's prompt gets three preamble lines: it runs in its own container, the declared sidecars are already up (or it must bring the whole stack up), commit as you go and push and open pull requests when the task calls for it — `GH_TOKEN` is in its environment and `gh stack` on its path — or leave it to the workflow. Exact wording in `AGENTS.md`.

Watch, answer or stop the run in the Claude app: **Code → `<repo>/<branch>`**. `gh run watch` shows the job; `gh run list --workflow cloud` the queue.

## 5. The end

Nothing to do on the client. The last step always runs, even after a cancel or timeout: it tears the containers down, commits what the session left as `run: <branch>` on the branch it left checked out (the dispatched one, or the top of a stack it cut), pushes that branch, and opens a draft pull request — or leaves the existing one alone, the session's own included. No changes → no push: `no changes on <branch>` in the log, which says nothing about what the session pushed itself: a stack's branches and pull requests are on GitHub, not in the log. Then `git pull` (or `git fetch origin` for a stack), review, mark ready.

To cancel: stop the session in the Claude app (seen within 30 s), or `gh run cancel <id>` — the last step still runs, and the session stays listed for the next run to resume. A session blocked on an unanswered question holds its runner until the 23-hour timeout.

## 6. Looking at the host

```bash
gh run list --workflow cloud                                    # every run
gh run view <id> --log | tail -50                               # what session printed
ssh agent@vps 'docker ps --format "{{.Names}}\t{{.Status}}"'   # cloud-<run id> is the agent, cloud-<run id>-postgres-1 a sidecar
ssh agent@vps 'sudo systemctl status "actions.runner.*"'       # the runners
```

The session's own screen is in the Claude app. `claude logs <id>` runs as `docker exec cloud-<run id> claude logs <id>`.

## 7. Upgrading

- **Claude Code, pnpm, the MCP, `gh`, `gh stack`, `session`**: bump the `ARG` in the `Dockerfile` or edit the script; `bash test.sh` and `bash test.sh image`; push to `main`. Then one probe on a scratch branch: `gh workflow run cloud --ref probe -f prompt="Bring the stack up, open the web app in Chrome through the chrome-devtools MCP, report document.title, then stop everything you started"`. Only that run tests the network, Chromium, Remote Control and the plugins on the real host.
- **Docker, Compose, `git`, `jq`, `gh` on the host**: `apt upgrade`, as root. The runners update themselves.
- **Your Claude setup**: the two lines of §3.2.
- **The login**: §3.1 again every 30 days, the refresh grant's cap; `claude auth logout` first after any doubt about the box.
