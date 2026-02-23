# CLAUDE.md — Ralph Loop Project Conventions

This file provides context and conventions for Claude sessions operating within the Ralph self-improvement loop.

## What this project is

Ralph is an agentic loop where Claude iterates autonomously on a software project. Each iteration:
1. Reads `PRD.md` to find the next unchecked task
2. Implements the task
3. Appends `[DONE] <task description>` to `progress.txt`
4. Outputs `<promise>COMPLETE</promise>` when all tasks are done

State is maintained entirely through files on disk — there is no shared memory between sessions.

## Key files

| File | Purpose |
|------|---------|
| `PRD.md` | Source of truth for tasks. Do not check off boxes; use `progress.txt` instead. |
| `progress.txt` | Append-only log of completed tasks. Read this to know what's already done. |
| `ralph.sh` | Automated loop: spawns Claude once per iteration with retry logic and logging. |
| `ralph-once.sh` | Single-iteration runner for manual step-through. |
| `docker-ralph.sh` | Runs the loop inside a sandboxed Docker container (macOS). |
| `entrypoint.sh` | Docker entrypoint: restores Claude credentials inside the container. |
| `logs/` | Per-run logs written by `ralph.sh` (created automatically, do not commit). |
| `.claude-auth/` | Exported Claude credentials for Docker use (gitignored, do not commit). |

## Task conventions

- **Pick tasks in order.** Always implement the first uncompleted task in `PRD.md`.
- **One task per session.** Do exactly one task, then stop.
- **Mark completion correctly.** Append `[DONE] <task description>` to `progress.txt`. Do not modify `PRD.md` checkboxes.
- **Completion signal.** After all tasks are done, output the token `<promise>COMPLETE</promise>` and nothing else needs to be done.

## Determining what's completed

Cross-reference `PRD.md` tasks against `progress.txt` entries. A task is done if a `[DONE]` line in `progress.txt` matches its description closely enough to identify it.

## Code style

- Shell scripts use `bash` with `set -euo pipefail` (or `set -uo pipefail` for loops that handle errors internally).
- Prefer simple, readable shell over clever one-liners.
- Log meaningful progress to stdout and to log files where applicable.

## Do not

- Commit files without being asked to (unless a task explicitly requires it).
- Edit `PRD.md` to mark tasks complete — use `progress.txt` only.
- Create unnecessary files or over-engineer solutions.
- Guess at ambiguous requirements — implement the most straightforward reading of each task.
