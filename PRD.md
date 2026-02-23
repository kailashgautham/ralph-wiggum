# Ralph Self-Improvement Plan

Ralph is a self-improving loop. Each iteration, Claude reads this file and progress.txt, picks the next uncompleted task, implements it, commits the change, and marks it done.

**Important:** If all tasks are completed, review the codebase for weaknesses and append new improvement tasks to the Tasks section below before proceeding. There should always be work to do.

## Tasks

- [ ] Forward RALPH_MAX_STALLS from docker-ralph.sh into the container: docker-ralph.sh already forwards CLAUDE_MODEL, RALPH_TIMEOUT, and MAX_RETRIES via `docker run -e`, but omits RALPH_MAX_STALLS; add it to the ENV_ARGS block so callers can tune stall sensitivity without rebuilding the image
- [ ] Add a flock-based lockfile to ralph-once.sh: ralph.sh prevents concurrent runs with flock on .ralph.lock, but ralph-once.sh has no such guard; a second simultaneous invocation can corrupt progress.txt and cause competing git commits; apply the same flock pattern
- [ ] Add retry logic to the COMPLETE planning call in ralph.sh and ralph-once.sh: the main Claude invocation uses MAX_RETRIES with a delay loop, but the planning call after `<promise>COMPLETE</promise>` fires once with no retry; wrap it in the same retry loop so a transient API error doesn't abort the planning step
- [ ] Add --verbose flag to the Claude invocation in ralph-once.sh: ralph.sh passes `--verbose` so tool calls and reasoning are visible in real time, but ralph-once.sh omits it, producing sparse output; add `--verbose` to the CMD array in ralph-once.sh for consistent observability
- [ ] Switch retry delay in ralph.sh to exponential backoff: the current fixed 5-second RETRY_DELAY is too short for API rate-limit errors on later attempts; replace it with exponential backoff (e.g. delay = RETRY_DELAY * 2^(attempt-1), capped at 60 seconds) so repeated failures back off gracefully
- [ ] Add credentials cleanup to the docker-ralph.sh cleanup subcommand: the cleanup command removes containers and images but leaves .claude-auth/ on disk; after removing Docker artifacts, also delete .claude-auth/ (with a confirmation prompt) so sensitive credentials are not left behind after a Docker teardown
- [ ] Switch ralph-once.sh to per-run timestamped log files: ralph-once.sh appends all output to a single logs/ralph-once.log that grows unboundedly; create a new timestamped log file per invocation (e.g. logs/once_YYYYMMDD_HHMMSS.log) matching the pattern used by ralph.sh
- [ ] Add kailash.gautham@gmail.com, Kailash Gautham as the main committer and co-authored by ralph. And use a PR and merging workflow.
