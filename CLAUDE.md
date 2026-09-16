## What this is

A GitHub Actions workflow runs a Claude Code session on a self-hosted runner, in a container from this repository's image, on the branch it is dispatched with, and pushes the result back as a draft pull request. `README.md` is the runbook: install, login, a run, the end. This file is what a project must bring to be run here, and the rules of this repository.

## What a project brings

One file, `.github/workflows/cloud.yml`, copied from `workflow.yml` here, plus the repository secrets it names. Nothing else in the project exists for the runner's sake: the session brings the stack up from the project's own README, `CLAUDE.md` and `docker-compose.yml`.

### `.github/workflows/cloud.yml`

The template as is, with two blocks edited:

- `services:`: one entry per service of `docker-compose.yml`, under the same name, with the same image and environment, its healthcheck as `options: --health-cmd …`, and no `ports`. Nothing in a run is published; several runs share the host.
- `env:` of the job: the keys of the project's `.env.example` files, each sidecar at its service name (`postgres:5432`, not `localhost`), the app's own servers at `localhost`. Dev values are written in the file, as CI writes them; a value that must not be in the tree is a repository secret, `gh secret set NAME`, read as `${{ secrets.NAME }}`. Dev credentials only: nothing that reaches a real bucket, a real database or a real mailbox.

Everything else stays: the `container:` block (image, the two mounts, the home, the seed), `permissions`, `concurrency`, `timeout-minutes`, the checkout without credentials, the `session` step, the last step. A project without `docker-compose.yml` deletes `services:` and gets a prompt that says to bring the whole stack up.

### What the run reads from the project

- The branch as pushed to GitHub: the result comes back as commits on it, pushed with the job's token, with a draft pull request. What is not pushed does not travel: an ignored brief goes in the prompt, `-f prompt="$(cat plan.md)"`.
- The prompt, from `gh workflow run cloud --ref <branch> -f prompt="…"`.
- The repository settings of README §3.4: Actions may create pull requests; `main` protected.

## Rules of this repository

- One script, `session`, one job: the step that launches and holds the session. What happens before it (checkout, sidecars) and after it (commit, push, pull request) is the workflow's, in `workflow.yml`, in plain `run:` steps. A behaviour goes in the one of the two that owns it, not in a new file.
- `test.sh` is the specification of `session`. A behaviour change adds or changes a `check` line first; the `claude` stub grows only what a check needs. `bash test.sh` must pass before a push; `bash test.sh image` after any change to the `Dockerfile`; `image.yml` runs both before it pushes the image.
- `README.md` names every step, refusal and message the code has. A change to one is a change to both.
- `session` carries a short header (what it is) and a comment above each helper saying what it is for. `workflow.yml` carries one comment above each of the two blocks a project edits. No other comments: what a line does is said by the line, and what a reader would get wrong goes in the README.
