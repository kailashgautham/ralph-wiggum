# ralph-wiggum

A template for running the **Ralph Loop** — an agentic workflow where Claude Code iterates autonomously on a project, one task at a time, using files on disk as state.

## How it works

Each iteration spawns a fresh Claude session with no prior context. State is maintained entirely through `PRD.md` (the plan) and `progress.txt` (completed tasks). This prevents context window degradation over long projects.

## Usage

### 1. Create a new project from this template

```bash
gh repo create my-project --template kailashgautham/ralph-wiggum --clone
cd my-project
```

### 2. Fill in `PRD.md`

Break your project into small, atomic tasks — each should be completable in a single Claude session.

### 3. Run the loop

**Single iteration (manual step-through):**
```bash
./ralph-once.sh
```

**Automated loop (runs until complete or max iterations):**
```bash
./ralph.sh           # default 20 iterations
./ralph.sh 10        # custom max
```

The loop exits automatically when Claude outputs `<promise>COMPLETE</promise>`.

## Files

| File | Purpose |
|------|---------|
| `PRD.md` | Project plan with task checklist |
| `progress.txt` | Completed task log (written by the agent) |
| `ralph-once.sh` | Single iteration script |
| `ralph.sh` | Automated loop script |
