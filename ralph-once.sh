#!/usr/bin/env bash
# ralph-once.sh — Run a single Ralph iteration (one Claude session).
# Usage: ./ralph-once.sh

set -euo pipefail

CLAUDE_MODEL=${CLAUDE_MODEL:-}
RALPH_TIMEOUT=${RALPH_TIMEOUT:-}

LOGS_DIR="logs"
mkdir -p "$LOGS_DIR"

# --- pre-flight checks ---
for _bin in claude git; do
  if ! command -v "$_bin" &>/dev/null; then
    echo "Error: '$_bin' not found in PATH. Please install it and ensure it is on your PATH." >&2
    exit 1
  fi
done
if [ ! -f "PRD.md" ]; then
  echo "Error: PRD.md not found in the current directory. Please run ralph from the project root." >&2
  exit 1
fi

DEFAULT_PROMPT="You are working on a software project. Read PRD.md for the full plan and progress.txt for completed tasks.
Pick the next uncompleted task from PRD.md, implement it, then append a line to progress.txt in the format:
  [DONE] <task description>
When ALL tasks in PRD.md are complete, output the token: <promise>COMPLETE</promise>"

if [ -f "prompt.txt" ]; then
  PROMPT=$(cat prompt.txt)
  echo "Using prompt from prompt.txt"
else
  PROMPT="$DEFAULT_PROMPT"
fi

# Build command as array to avoid shell injection from PROMPT content
CMD=(claude -p "$PROMPT" --allowedTools "Edit,Write,Bash,Read,Glob,Grep")
if [ -n "$CLAUDE_MODEL" ]; then
  CMD+=(--model "$CLAUDE_MODEL")
fi

# Stream output to terminal in real-time while capturing it to a temp file
TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT

set +e
if [ -n "$RALPH_TIMEOUT" ]; then
  timeout "$RALPH_TIMEOUT" "${CMD[@]}" 2>&1 | tee "$TMPFILE"
else
  "${CMD[@]}" 2>&1 | tee "$TMPFILE"
fi
CLAUDE_EXIT=${PIPESTATUS[0]}
set -e

OUTPUT=$(cat "$TMPFILE")

if [ "$CLAUDE_EXIT" -eq 124 ]; then
  echo "Error: Claude invocation timed out after ${RALPH_TIMEOUT}s" >&2
  exit 124
fi
if [ "$CLAUDE_EXIT" -ne 0 ]; then
  echo "Error: Claude CLI exited with code $CLAUDE_EXIT" >&2
  exit "$CLAUDE_EXIT"
fi

if git diff --quiet && git diff --cached --quiet; then
  echo "No changes to commit."
else
  git add -A
  LAST_DONE=$(grep '^\[DONE\]' progress.txt 2>/dev/null | tail -1 | sed 's/^\[DONE\] //')
  if [ -n "$LAST_DONE" ]; then
    COMMIT_MSG="ralph: ${LAST_DONE} (single iteration)"
  else
    COMMIT_MSG="ralph: completed task (single iteration)"
  fi
  if git commit -m "$COMMIT_MSG"; then
    echo "Committed changes."
    if git push; then
      echo "Pushed changes to remote."
    else
      echo "Warning: git push failed." >&2
    fi
  else
    echo "Warning: git commit failed." >&2
  fi
fi

if echo "$OUTPUT" | grep -q "<promise>COMPLETE</promise>"; then
  echo ""
  echo "=== All tasks complete. Generating new tasks... ===" | tee -a "$LOGS_DIR/ralph-once.log"

  PLAN_PROMPT="Review the codebase in this directory. The project is a self-improving agentic loop called Ralph. All tasks in PRD.md have been completed (see progress.txt). Your job is to review the code for weaknesses, missing features, or further improvements, then REWRITE the Tasks section in PRD.md with a fresh list of at least 5 unchecked improvement tasks in the format '- [ ] task description'. Replace the existing task list entirely with the new one. Do not modify progress.txt or check off any boxes."

  PLAN_CMD=(claude -p "$PLAN_PROMPT" --allowedTools "Edit,Write,Bash,Read,Glob,Grep")
  if [ -n "$CLAUDE_MODEL" ]; then
    PLAN_CMD+=(--model "$CLAUDE_MODEL")
  fi
  if [ -n "$RALPH_TIMEOUT" ]; then
    timeout "$RALPH_TIMEOUT" "${PLAN_CMD[@]}" 2>&1 | tee -a "$LOGS_DIR/ralph-once.log"
  else
    "${PLAN_CMD[@]}" 2>&1 | tee -a "$LOGS_DIR/ralph-once.log"
  fi

  # Archive completed progress entries and reset progress.txt for the new cycle.
  ARCHIVE_FILE="$LOGS_DIR/progress_archive_$(date +%Y%m%d_%H%M%S).txt"
  cp progress.txt "$ARCHIVE_FILE"
  printf "# Progress Tracker\n# Each completed task is logged here by the agent.\n# Format: [DONE] Task description\n" > progress.txt
  echo "Archived progress.txt to $ARCHIVE_FILE and reset for new cycle."

  if ! git diff --quiet || ! git diff --cached --quiet; then
    git add -A
    if git commit -m "ralph: rewrite PRD.md tasks for next cycle (single iteration)"; then
      echo "Committed new tasks."
      if git push; then
        echo "Pushed new tasks to remote."
      else
        echo "Warning: git push failed after task rewrite." >&2
      fi
    else
      echo "Warning: git commit failed after task rewrite." >&2
    fi
  fi

  exit 0
fi
