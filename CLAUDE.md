## What this is

A GitHub Actions workflow runs a Claude Code session on a self-hosted runner, in a container from this repository's image, on the branch it is dispatched with, and pushes the result back as a draft pull request. `README.md` is the runbook: install, login, a run, the end. `AGENTS.md` is the reference: every step, state, message and refusal. This file is what a project must bring to be run here, and the rules of this repository.

## What a project brings

One file, `.github/workflows/cloud.yml`, copied from `workflow.yml` here, plus the repository secrets it names. Nothing else in the project exists for the runner's sake: the job brings `docker-compose.yml` up as is, and the session brings the rest of the stack up from the project's own README and `CLAUDE.md`.

### `.github/workflows/cloud.yml`

The template as is, with one block edited:

- `env:` of the job: the keys of the project's `.env.example` files, each service of `docker-compose.yml` at its service name (`postgres:5432`, not `localhost`), the app's own servers at `localhost`. Dev values are written in the file, as CI writes them; a value that must not be in the tree is a repository secret, `gh secret set NAME`, read as `${{ secrets.NAME }}`. Dev credentials only: nothing that reaches a real bucket, a real database or a real mailbox.

Everything else stays: `permissions`, `concurrency`, `timeout-minutes`, the checkout without credentials, the session step (Compose up from `docker-compose.yml` with its ports reset, then `docker run` of the agent image on that network), the last step. The sidecars are never retyped: the step reads `docker-compose.yml` as is, and a project without one skips Compose and gets a prompt that says to bring the whole stack up.

### What the run reads from the project

- The branch as pushed to GitHub: the result comes back as commits on it, pushed with the job's token, with a draft pull request. What is not pushed does not travel: an ignored brief goes in the prompt, `-f prompt="$(cat plan.md)"`.
- The prompt, from `gh workflow run cloud --ref <branch> -f prompt="…"`.
- The repository settings of README §3.4: Actions may create pull requests; `main` protected.

## Rules of this repository

- One script, `session`, one job: the step that launches and holds the session. What happens before it (checkout, sidecars) and after it (commit, push, pull request) is the workflow's, in `workflow.yml`, in plain `run:` steps. A behaviour goes in the one of the two that owns it, not in a new file.
- `test.sh` is the specification of `session`. A behaviour change adds or changes a `check` line first; the `claude` stub grows only what a check needs. `bash test.sh` must pass before a push; `bash test.sh image` after any change to the `Dockerfile`; `image.yml` runs both before it pushes the image.
- `AGENTS.md` names every step, refusal and message the code has; `README.md` is the runbook a human follows. A behaviour change is a change to `AGENTS.md` too, and to the README where a hand would meet it.
- `session` carries a short header (what it is) and a comment above each helper saying what it is for. `workflow.yml` carries one comment above the block a project edits. No other comments: what a line does is said by the line, and what a reader would get wrong goes in the README.
