#!/usr/bin/env bash
# ralph-once.sh — Run a single Ralph iteration (one Claude session).
# Usage: ./ralph-once.sh

set -euo pipefail

CLAUDE_MODEL=${CLAUDE_MODEL:-}
RALPH_TIMEOUT=${RALPH_TIMEOUT:-}
MAX_RETRIES=${MAX_RETRIES:-3}
RETRY_DELAY=${RALPH_RETRY_DELAY:-5}
RALPH_ALLOWED_TOOLS=${RALPH_ALLOWED_TOOLS:-"Edit,Write,Bash,Read,Glob,Grep"}
RALPH_BASE_BRANCH=${RALPH_BASE_BRANCH:-main}

LOGS_DIR="logs"
mkdir -p "$LOGS_DIR"
RUN_LOG="$LOGS_DIR/once_$(date +%Y%m%d_%H%M%S).log"

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

# --- lockfile: prevent concurrent invocations ---
LOCKFILE=".ralph.lock"
exec 9>"$LOCKFILE"
if ! flock -n 9; then
  echo "Error: another instance of ralph is already running (lockfile: $LOCKFILE). Aborting." >&2
  exit 1
fi

RUN_HEADER="=== Ralph single iteration === $(date '+%Y-%m-%d %H:%M:%S') ==="
echo "$RUN_HEADER" | tee -a "$RUN_LOG"

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
CMD=(claude -p "$PROMPT" --allowedTools "$RALPH_ALLOWED_TOOLS" --verbose)
if [ -n "$CLAUDE_MODEL" ]; then
  CMD+=(--model "$CLAUDE_MODEL")
fi

# Stream output to terminal in real-time while capturing it to a temp file
TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE" "$LOCKFILE"' EXIT

ATTEMPT=1
CLAUDE_EXIT=1
while [ $ATTEMPT -le $MAX_RETRIES ]; do
  set +e
  if [ -n "$RALPH_TIMEOUT" ]; then
    timeout "$RALPH_TIMEOUT" "${CMD[@]}" 2>&1 | tee "$TMPFILE"
  else
    "${CMD[@]}" 2>&1 | tee "$TMPFILE"
  fi
  CLAUDE_EXIT=${PIPESTATUS[0]}
  set -e

  if [ "$CLAUDE_EXIT" -eq 124 ]; then
    echo "Warning: Claude invocation timed out after ${RALPH_TIMEOUT}s (attempt $ATTEMPT/$MAX_RETRIES)" >&2
  fi
  if [ "$CLAUDE_EXIT" -eq 0 ]; then
    break
  fi
  echo "Warning: Claude CLI failed (attempt $ATTEMPT/$MAX_RETRIES, exit code $CLAUDE_EXIT)" >&2
  if [ $ATTEMPT -lt $MAX_RETRIES ]; then
    BACKOFF=$(( RETRY_DELAY * (1 << (ATTEMPT - 1)) ))
    if [ "$BACKOFF" -gt 60 ]; then BACKOFF=60; fi
    echo "Retrying in ${BACKOFF}s..." >&2
    sleep "$BACKOFF"
  fi
  ATTEMPT=$((ATTEMPT + 1))
done

OUTPUT=$(cat "$TMPFILE")
echo "$OUTPUT" >> "$RUN_LOG"

if [ "$CLAUDE_EXIT" -eq 124 ]; then
  echo "Error: Claude invocation timed out after ${RALPH_TIMEOUT}s" >&2
  exit 124
fi
if [ "$CLAUDE_EXIT" -ne 0 ]; then
  echo "Error: Claude CLI failed after $MAX_RETRIES attempts (exit code $CLAUDE_EXIT)." >&2
  exit "$CLAUDE_EXIT"
fi

if git diff --quiet && git diff --cached --quiet; then
  echo "No changes to commit."
else
  LAST_DONE=$(grep '^\[DONE\]' progress.txt 2>/dev/null | tail -1 | sed 's/^\[DONE\] //')
  if [ -n "$LAST_DONE" ]; then
    COMMIT_MSG="ralph: ${LAST_DONE} (single iteration)"
  else
    COMMIT_MSG="ralph: completed task (single iteration)"
  fi
  BRANCH_NAME="ralph/once-$(date +%Y%m%d_%H%M%S)"
  git checkout -b "$BRANCH_NAME"
  git add -A
  if git commit -m "$(printf '%s\n\nCo-Authored-By: Ralph Wiggum <ralph@wiggum.bot>' "$COMMIT_MSG")"; then
    echo "Committed changes."
    if git remote get-url origin &>/dev/null; then
      if git push -u origin "$BRANCH_NAME"; then
        echo "Pushed branch $BRANCH_NAME to remote."
        if command -v gh &>/dev/null; then
          if PR_URL=$(gh pr create --title "$COMMIT_MSG" --body "Automated PR from Ralph single iteration." --base "$RALPH_BASE_BRANCH" 2>&1); then
            echo "Created PR: $PR_URL"
            gh pr merge --squash --delete-branch "$PR_URL" 2>&1 || echo "Warning: PR merge failed." >&2
          else
            echo "Warning: gh pr create failed: $PR_URL" >&2
          fi
        else
          echo "Warning: gh CLI not found, skipping PR creation." >&2
        fi
      else
        echo "Warning: git push failed." >&2
      fi
    else
      echo "Info: No remote 'origin' configured, skipping push."
    fi
  else
    echo "Warning: git commit failed." >&2
  fi
  git checkout "$RALPH_BASE_BRANCH"
  git pull --ff-only origin "$RALPH_BASE_BRANCH" 2>/dev/null || true
fi

if echo "$OUTPUT" | grep -q "<promise>COMPLETE</promise>"; then
  echo ""
  echo "=== All tasks complete. Generating new tasks... ===" | tee -a "$RUN_LOG"

  PLAN_PROMPT="Review the codebase in this directory. The project is a self-improving agentic loop called Ralph. All tasks in PRD.md have been completed (see progress.txt). Your job is to review the code for weaknesses, missing features, or further improvements, then REWRITE the Tasks section in PRD.md with a fresh list of at least 5 unchecked improvement tasks in the format '- [ ] task description'. Replace the existing task list entirely with the new one. Do not modify progress.txt or check off any boxes."

  PLAN_CMD=(claude -p "$PLAN_PROMPT" --allowedTools "$RALPH_ALLOWED_TOOLS")
  if [ -n "$CLAUDE_MODEL" ]; then
    PLAN_CMD+=(--model "$CLAUDE_MODEL")
  fi
  PLAN_ATTEMPT=1
  PLAN_EXIT=1
  while [ $PLAN_ATTEMPT -le $MAX_RETRIES ]; do
    if [ -n "$RALPH_TIMEOUT" ]; then
      timeout "$RALPH_TIMEOUT" "${PLAN_CMD[@]}" 2>&1 | tee -a "$RUN_LOG"
    else
      "${PLAN_CMD[@]}" 2>&1 | tee -a "$RUN_LOG"
    fi
    PLAN_EXIT=${PIPESTATUS[0]}
    if [ "$PLAN_EXIT" -eq 0 ]; then
      break
    fi
    echo "Warning: Planning call failed (attempt $PLAN_ATTEMPT/$MAX_RETRIES, exit code $PLAN_EXIT)" >&2
    if [ $PLAN_ATTEMPT -lt $MAX_RETRIES ]; then
      BACKOFF=$(( RETRY_DELAY * (1 << (PLAN_ATTEMPT - 1)) ))
      if [ "$BACKOFF" -gt 60 ]; then BACKOFF=60; fi
      echo "Retrying planning call in ${BACKOFF}s..." >&2
      sleep "$BACKOFF"
    fi
    PLAN_ATTEMPT=$((PLAN_ATTEMPT + 1))
  done
  if [ "$PLAN_EXIT" -ne 0 ]; then
    echo "Warning: Planning call failed after $MAX_RETRIES attempts. Proceeding with archive/reset." >&2
  fi

  # Archive completed progress entries and reset progress.txt for the new cycle.
  ARCHIVE_FILE="$LOGS_DIR/progress_archive_$(date +%Y%m%d_%H%M%S).txt"
  cp progress.txt "$ARCHIVE_FILE"
  printf "# Progress Tracker\n# Each completed task is logged here by the agent.\n# Format: [DONE] Task description\n" > progress.txt
  echo "Archived progress.txt to $ARCHIVE_FILE and reset for new cycle."

  if ! git diff --quiet || ! git diff --cached --quiet; then
    CYCLE_BRANCH="ralph/cycle-rewrite-$(date +%Y%m%d_%H%M%S)"
    git checkout -b "$CYCLE_BRANCH"
    git add -A
    if git commit -m "$(printf 'ralph: rewrite PRD.md tasks for next cycle (single iteration)\n\nCo-Authored-By: Ralph Wiggum <ralph@wiggum.bot>')"; then
      echo "Committed new tasks."
      if git remote get-url origin &>/dev/null; then
        if git push -u origin "$CYCLE_BRANCH"; then
          echo "Pushed branch $CYCLE_BRANCH to remote."
          if command -v gh &>/dev/null; then
            if PR_URL=$(gh pr create --title "ralph: rewrite PRD.md tasks for next cycle" --body "Automated cycle rewrite from Ralph single iteration." --base "$RALPH_BASE_BRANCH" 2>&1); then
              echo "Created PR: $PR_URL"
              gh pr merge --squash --delete-branch "$PR_URL" 2>&1 || echo "Warning: PR merge failed." >&2
            else
              echo "Warning: gh pr create failed: $PR_URL" >&2
            fi
          fi
        else
          echo "Warning: git push failed after task rewrite." >&2
        fi
      else
        echo "Info: No remote 'origin' configured, skipping push after task rewrite."
      fi
    else
      echo "Warning: git commit failed after task rewrite." >&2
    fi
    git checkout "$RALPH_BASE_BRANCH"
    git pull --ff-only origin "$RALPH_BASE_BRANCH" 2>/dev/null || true
  fi

  exit 0
fi
