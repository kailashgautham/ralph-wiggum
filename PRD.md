# Ralph Self-Improvement Plan

Ralph is a self-improving loop. Each iteration, Claude reads this file and progress.txt, picks the next uncompleted task, implements it, commits the change, and marks it done.

**Important:** If all tasks are completed, review the codebase for weaknesses and append new improvement tasks to the Tasks section below before proceeding. There should always be work to do.

## Tasks

- [ ] Add pre-flight dependency checks to both ralph.sh and ralph-once.sh: before starting, verify that the `claude` and `git` binaries are in PATH and that PRD.md exists, printing a clear actionable error message and exiting non-zero if any check fails
- [ ] Sync ralph-once.sh COMPLETE handling with ralph.sh: when the output contains `<promise>COMPLETE</promise>`, rewrite PRD.md tasks via a planning Claude call and archive+reset progress.txt, instead of simply printing "All tasks complete" and exiting
- [ ] Fix ralph-once.sh commit message: extract the last [DONE] line from progress.txt and use it as the commit message (e.g. "ralph: <task description> (single iteration)") instead of the current generic hardcoded string
- [ ] Respect MAX_RETRIES environment variable in ralph.sh: the variable is forwarded by docker-ralph.sh but ralph.sh ignores it and always uses a hardcoded value of 3; read MAX_RETRIES from the environment (with 3 as the default) so callers can tune it without rebuilding the Docker image
- [ ] Add RALPH_TIMEOUT support to ralph-once.sh: ralph.sh wraps its Claude call with `timeout "$RALPH_TIMEOUT"` when the variable is set, but ralph-once.sh never does; apply the same conditional timeout so a hung single-iteration run can be interrupted
- [ ] Handle non-TTY environments in docker-ralph.sh: the `docker run` command unconditionally passes `-it`, which fails when stdout is not a terminal (CI pipelines, cron jobs, piped invocations); detect whether a TTY is available using `[ -t 1 ]` and only pass `-t` when running interactively
- [ ] Add stall detection to ralph.sh: after each iteration, compare the number of [DONE] lines in progress.txt before and after the Claude call; if the count did not increase, log a warning and increment a consecutive-stall counter; after N consecutive stalled iterations (default 3, configurable via RALPH_MAX_STALLS), exit with a non-zero code and a clear message instead of silently burning through remaining iterations

