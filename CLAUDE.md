## What this is

`cloud` runs a Claude Code session on a Docker host from the current branch of any project, and the host brings the result back as a draft pull request. `README.md` is the runbook: install, login, a run, the end. This file is what a project must bring to be run here, and the rules of this repository.

## What a project brings

One file, `cloud.yml` at the project's root, plus one `env` file typed on the host. Nothing else in the project exists for the host's sake: the session brings the stack up from the project's own README, `CLAUDE.md` and `docker-compose.yml`.

### `cloud.yml`

The Compose overlay of one run. It declares the `agent` service by extending `agent.yml`, and resets the published ports of every sidecar. `cloud run` refuses a project without it.

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

Rules:

- `extends` and `env_file: env` are always there. `${AGENT_ROOT}` and `env` are resolved on the host; `env` is `/opt/agent/projects/<project>/env`, never a file in the tree.
- One `depends_on` entry per sidecar the session must find up, with `condition: service_healthy` when the sidecar has a healthcheck, `service_started` otherwise.
- One `ports: !reset []` per service of `docker-compose.yml` that publishes a port. Nothing in a run is published; several runs share the host.
- The sidecars are never redeclared here: `docker-compose.yml` is shipped as `stack.yml` and read first. Only that name is read; `compose.yaml` is not.
- A project without `docker-compose.yml` has an overlay of the `agent` service alone, and its prompt says to bring the whole stack up.

### `env` on the host

`/opt/agent/projects/<project>/env`, `chmod 600`, one `KEY=value` per line: the keys of the project's `.env.example` files, with each sidecar at its service name (`postgres:5432`, not `localhost`). Dev credentials only. `<project>` is the origin repository's name, lowercased, non-alphanumerics replaced by `-`.

### What the run reads from the project

- The branch as committed: `cloud run` refuses a dirty tree, and the result comes back as commits on that branch, pushed to origin with a draft pull request.
- The prompt, or a file: `cloud run "…"` or `cloud run path/to/plan.md`.
- `.claude/` in full except `worktrees/`, tracked or ignored: briefs, plans, skills, settings. It travels one way; what the run writes there does not come back.
- On the host, `gh` logged in with a token that may push branches and open pull requests on the project's origin; `main` protected there.

## Rules of this repository

- One script, `cloud`, three sides: the client verbs, the `host-*` verbs and the `session` verb, dispatched on `$1`. A behaviour goes in the verb that owns it, not in a new file. The client is any machine with git, ssh and rsync; nothing in the client verbs may assume a person is there, so a GitHub Action can run them.
- `test.sh` is the specification. A behaviour change adds or changes a `check` line first; the stubs (`docker`, `claude`, `gh`, `ssh`) grow only what a check needs. `bash test.sh` must pass before a push; `bash test.sh image` after any change to the `Dockerfile`.
- `README.md` names every verb, refusal and message the code has. A change to one is a change to both.
- `cloud` carries a short header (what it is, the host layout) and a comment above each verb and helper saying what it is for and what it must not do. No other comments: what a line does is said by the line, and what a reader would get wrong goes in the README.
