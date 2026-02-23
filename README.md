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
