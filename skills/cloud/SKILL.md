---
name: cloud
description: Dispatch the current branch to the remote agent host — push it, run the project's `cloud` workflow with a prompt, watch the run, report the branch and pull request. A session already named after the branch is resumed unless the user asks for a fresh one. Use when the user says "cloud this", "send this to the cloud", "run this remotely", "resume the cloud run", or invokes /cloud.
---

# /cloud [fresh] [prompt]

A leading word `fresh` is the flag of §4, not part of the prompt; everything after it is the prompt. Runs from inside the project's checkout, on the client. Everything below is a command to run as written; the two places that take judgment are marked **decide**.

## 1. Refuse what does not travel

```sh
cd "$(git rev-parse --show-toplevel)"
[ -f .github/workflows/cloud.yml ] || { echo 'no cloud workflow in this project — README §3.3 of remote-agent'; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo 'uncommitted changes; commit first — what is not pushed does not travel'; exit 1; }
repo=$(gh repo view --json name -q .name); current=$(git branch --show-current)
```

A dirty tree is a stop, not a question: the run works on the branch as pushed, and anything left here would be missing there.

## 2. What the host holds

One ssh round trip, the same `docker run` as README §3.1 (`vps`: the ssh alias for the host, README §1):

```sh
ssh agent@vps 'docker run --rm -v /opt/agent/home:/home/agent ghcr.io/qrafttech/agent sh -c "claude auth status; claude agents --json --all"'
```

- No `"loggedIn": true` → stop: `the host is not logged in; log in first, README §3.1`.
- Filter the listing on `name == "<repo>/<current>"` and print what is there, newest first: id, state, started (as an age). A session whose run is in progress right now shows `failed` from here (its process is in the job's container, out of this listing's sight) — check `gh run list --workflow cloud --branch <current>` before reading `failed` as dead; the same branch queues behind itself anyway. This is what the run will resume — on `main` there is never one, the run gets its own branch (§5).

## 3. **Decide** — the prompt

Given with the call → as is. Not given → compose it from what the session holds: the brief, the plan just settled, the thing the user asked to send. Show it before dispatching. For a resume, the prompt says what to do next ("resume the implement loop; the log is in .git/implement-loop.log"), not what the run was: it is the session's next turn. Nothing to say → leave it empty and pass no prompt; the workflow's default is `Continue where you left off.`

## 4. **Decide** — fresh or resumed

The workflow resumes the newest listed session of that name unless told `fresh`. Choose `fresh` when the user said so, or when the listed session ended (`done`, `stopped`) and the prompt is a new task rather than a continuation. Otherwise resume: a session that stopped mid-task, was paused, or is `blocked` on a question carries the context the next turn needs. Say which you chose and why, in one line. No session listed → nothing to decide.

A resumed session re-reads its whole transcript first; a long one starts near compaction. That is the one reason to prefer `fresh` for a task the old session need not remember.

## 5. The setup, the branch, the push, the dispatch

```sh
rsync -aR --delete --exclude .DS_Store --exclude /skills/synced/ ~/.claude/./{CLAUDE.md,settings.json,notify.sh,rules,commands,agents,agent-memory,skills,plugins} agent@vps:/opt/agent/home/.claude/ &&
branch=$current
[ "$current" != main ] || branch="cloud/$(date +%m%d-%H%M)-$(printf '%s' "$prompt" | tr -cs 'a-zA-Z0-9' '-' | tr 'A-Z' 'a-z' | cut -c1-40 | sed 's/-$//')"
args=(); [ -z "$prompt" ] || args+=(-f "prompt=$prompt"); [ "$fresh" != true ] || args+=(-f fresh=true)
[ ${#args[@]} -gt 0 ] || args+=(-f fresh=false)   # gh asks interactively when no input is given at all
last=$(gh run list --workflow cloud --branch "$branch" --limit 1 --json databaseId -q '.[0].databaseId')
git push -q origin "HEAD:refs/heads/$branch" &&
gh workflow run cloud --ref "$branch" "${args[@]}" &&
until run=$(gh run list --workflow cloud --branch "$branch" --limit 1 --json databaseId -q '.[0].databaseId') && [ -n "$run" ] && [ "$run" != "$last" ]; do sleep 3; done &&
echo "run $run on $branch"
```

The rsync ships `~/.claude` as it is on the client — skills, rules, settings, plugins — so the run holds what this session holds; a failed rsync stops here. On `main` the run gets its own branch, named from the prompt; on any other branch the run continues that branch. A rejected push stops here — pull first, nothing was dispatched. A prompt is passed only when there is one (an empty `-f prompt=` would replace the workflow's default with nothing), and `fresh` only when chosen.

## 6. Watch

A run lasts minutes to hours, longer than one tool call may block. Either hand the user the run and stop here — `gh run watch <run>`, and the session in the Claude app under **Code → `<repo>/<branch>`** — or, if they want the report, poll in the background:

```sh
until [ "$(gh run view "$run" --json status -q .status)" = completed ]; do sleep 60; done
```

## 7. Report

From `gh run view "$run" --log`: the `session <id> …` lines — `resumed from <session id>, running as` or `running as`, then the end (`done`, `idle, working by its own account`, or the error). Then:

```sh
if [ "$branch" = "$current" ]; then git pull --rebase -q origin "$branch"; else git fetch -q origin "$branch"; fi
since=$(gh run view "$run" --json createdAt -q .createdAt)
gh pr list --json url,isDraft,headRefName,baseRefName,updatedAt -q ".[] | select(.updatedAt >= \"$since\") | \"\(.url) \(.headRefName) → \(.baseRefName) draft=\(.isDraft)\""
```

Say what came back: the commits pulled (or fetched, when the run had its own branch off `main` — never rebase `main` onto them), every pull request the run opened or touched — the session pushes its own, a stack included, and the last step adds a draft on the branch for anything left unpushed — or `no changes on <branch>`. Branches the session pushed besides `$branch` are on `origin`, not local: `git fetch origin` to see them. The session stays listed on the host either way; the next `/cloud` on this branch resumes it.
