# ralph-wiggum

A template for running the **Ralph Loop** — an agentic workflow where Claude Code iterates autonomously on a project, one task at a time, using files on disk as state.

## How it works

Each iteration spawns a fresh Claude session with no prior context. State is maintained entirely through `PRD.md` (the plan) and `progress.txt` (completed tasks). This prevents context window degradation over long projects.

```
┌─────────────────────────────────────────────────────────┐
│                      ralph.sh loop                      │
│                                                         │
│  ┌──────────┐    ┌─────────────┐    ┌───────────────┐  │
│  │  PRD.md  │───▶│   Claude    │───▶│ progress.txt  │  │
│  │ (tasks)  │    │  (one-shot) │    │  (completed)  │  │
│  └──────────┘    └─────────────┘    └───────────────┘  │
│        ▲                │                               │
│        └── next task ───┘  repeat until COMPLETE        │
└─────────────────────────────────────────────────────────┘
```

Each Claude session:
1. Reads `PRD.md` to find the next unchecked task
2. Implements the task (edits files, runs commands, etc.)
3. Appends `[DONE] <task>` to `progress.txt`
4. Outputs `<promise>COMPLETE</promise>` when all tasks are done

The loop detects the completion token and exits.

## Quick start

### 1. Create a new project from this template

```bash
gh repo create my-project --template kailashgautham/ralph-wiggum --clone
cd my-project
```

### 2. Define your tasks in `PRD.md`

Break your project into small, atomic tasks — each should be completable in a single Claude session:

```markdown
## Tasks

- [ ] Scaffold a FastAPI project with a /health endpoint
- [ ] Add a PostgreSQL model for users using SQLAlchemy
- [ ] Write pytest tests for the /health endpoint
- [ ] Add a Dockerfile for the API service
```

### 3. Run the loop

**Single iteration (manual step-through):**
```bash
./ralph-once.sh
```

**Automated loop (runs until complete or max iterations):**
```bash
./ralph.sh           # default 20 iterations
./ralph.sh 10        # custom max iterations
```

**Sandboxed via Docker (macOS):**
```bash
./docker-ralph.sh setup   # one-time: exports credentials from Keychain
./docker-ralph.sh         # runs the loop inside a container
./docker-ralph.sh 10      # custom max iterations
```

## Files

| File | Purpose |
|------|---------|
| `PRD.md` | Project plan with task checklist |
| `progress.txt` | Completed task log (appended by the agent) |
| `ralph-once.sh` | Run a single Claude iteration manually |
| `ralph.sh` | Automated loop with retry logic and logging |
| `ralph-lib.sh` | Sourced helper library with shared functions (validation, git, PR helpers) |
| `docker-ralph.sh` | Run the loop inside a sandboxed Docker container |
| `Dockerfile` | Container image definition |
| `logs/` | Per-run logs written by `ralph.sh` (created automatically) |
| `tests/run_tests.sh` | Test harness that validates argument handling and core behaviour |

## Architecture

### State management

Ralph uses two plain-text files as its sole state:

- **`PRD.md`** — the source of truth for what needs to be done. Tasks follow the `- [ ]` / `- [x]` markdown checkbox convention (though Ralph uses `progress.txt` rather than editing checkboxes directly).
- **`progress.txt`** — an append-only log of completed tasks. Claude reads this each session to know what has already been done and skips those tasks.

### Retry logic

`ralph.sh` wraps each Claude call with up to 3 retries (5-second delay between attempts). If all retries fail, that iteration is skipped with a warning and the loop continues.

### Logging

Each run of `ralph.sh` writes a timestamped log file to `logs/run_YYYYMMDD_HHMMSS.log` containing iteration headers and full Claude output.

### Docker sandboxing

`docker-ralph.sh` builds a container image and mounts your project directory into it. Claude credentials are extracted from the macOS Keychain on first setup and stored in `.claude-auth/` (gitignored). The container runs `ralph.sh` against the mounted project files.

### Custom prompts

By default, both `ralph.sh` and `ralph-once.sh` send the following prompt to Claude on each iteration:

```
You are working on a software project. Read PRD.md for the full plan and progress.txt for completed tasks.
Pick the next uncompleted task from PRD.md, implement it, then append a line to progress.txt in the format:
  [DONE] <task description>
When ALL tasks in PRD.md are complete, output the token: <promise>COMPLETE</promise>
```

If a file named `prompt.txt` exists in the project root, both scripts will load it and use its contents as the prompt instead of the default. The scripts print `Using prompt from prompt.txt` when this override is active.

This is useful when you want to:
- Add project-specific context (e.g. technology constraints, coding standards, testing requirements)
- Change the task format or completion signal
- Inject additional instructions that apply to every iteration

**Example:** to tell Claude to always write tests alongside each change:

```
You are working on a software project. Read PRD.md for the full plan and progress.txt for completed tasks.
Pick the next uncompleted task from PRD.md, implement it, and write corresponding tests.
Then append a line to progress.txt in the format:
  [DONE] <task description>
When ALL tasks in PRD.md are complete, output the token: <promise>COMPLETE</promise>
```

Save this as `prompt.txt` in the project root and Ralph will use it on every subsequent iteration.

### Environment variables

Key variables accepted by both `ralph.sh` and `ralph-once.sh`:

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAUDE_MODEL` | claude default | Claude model to use |
| `RALPH_TIMEOUT` | none | Per-iteration timeout in seconds |
| `RALPH_ALLOWED_TOOLS` | `Edit,Write,Bash,Read,Glob,Grep` | Comma-separated Claude tools to allow |
| `RALPH_BASE_BRANCH` | `main` | Git base branch for PRs |
| `MAX_RETRIES` | `3` | Retry attempts on Claude CLI failure |
| `RALPH_RETRY_DELAY` | `5` | Base delay in seconds between retries |
| `RALPH_NO_GIT` | unset | Set to any non-empty value to skip all git operations (diff check, commit, push, and PR creation). Useful for local experimentation, environments without git configured, or when using a custom VCS workflow. |
| `RALPH_NO_PR` | unset | If non-empty, skip PR creation and leave the branch on the remote for manual review. |
| `RALPH_PLAN_PROMPT` | built-in | Override the planning prompt used when all tasks are complete. Defaults to the built-in review-and-rewrite prompt that asks Claude to generate a new task list. |

`ralph.sh` also accepts:

| Variable | Default | Description |
|----------|---------|-------------|
| `RALPH_MAX_STALLS` | `3` | Consecutive no-progress iterations before abort |
| `RALPH_LOG_KEEP` | `50` | Number of log files to retain (0 = keep all) |
| `RALPH_COMPLETE_HOOK` | unset | Shell command executed (via `eval`) immediately before any terminal exit. `RALPH_EXIT_REASON` is exported as `"complete"` (all tasks done and new tasks generated), `"stall"` (stall limit reached), or `"max_iterations"` (loop limit reached). Useful for notifications, e.g. `RALPH_COMPLETE_HOOK='curl -s -X POST "$WEBHOOK_URL" -d "{\"reason\":\"$RALPH_EXIT_REASON\"}"'`. |

**Example — run without any git operations:**
```bash
RALPH_NO_GIT=1 ./ralph-once.sh
RALPH_NO_GIT=1 ./ralph.sh 5
```

### Testing

The `tests/run_tests.sh` script validates argument handling and core behaviour for `ralph.sh`, `ralph-once.sh`, and `docker-ralph.sh`. Run it directly from the repo root:

```bash
bash tests/run_tests.sh
```

The harness reports each test as PASS or FAIL and exits non-zero if any test fails. No additional dependencies are required beyond standard POSIX utilities and `flock` (part of `util-linux`, available on most Linux distributions).

## Tips for writing good tasks

- **Keep tasks atomic** — one task should do one thing. "Add a login endpoint" is better than "Build the entire auth system".
- **Be explicit** — Claude has no memory between sessions. Include enough context in each task description for it to act without guessing.
- **Order matters** — tasks are picked in order, so sequence them so later tasks can build on earlier ones.
- **Avoid huge tasks** — if a task would take a human more than an hour, split it up.

## Example output

```
=== Ralph iteration 1/20 === 2025-01-15 10:23:01 ===
[Claude implements task 1...]

=== Ralph iteration 2/20 === 2025-01-15 10:24:38 ===
[Claude implements task 2...]

=== All tasks complete after 2 iteration(s). ===
```
