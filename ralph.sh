#!/usr/bin/env bash
# ralph.sh — Automated Ralph Loop. Runs Claude in a fresh context each iteration.
# Usage: ./ralph.sh [max_iterations]

set -uo pipefail

# --- status subcommand ---
if [ "${1:-}" = "status" ]; then
  echo "=== Ralph Status ==="

  if [ ! -f "PRD.md" ]; then
    echo "Error: PRD.md not found." >&2
    exit 1
  fi

  # Extract task descriptions from PRD.md (both unchecked and checked boxes)
  mapfile -t ALL_TASKS < <(grep -E '^\- \[[ x]\] ' PRD.md | sed 's/^- \[[ x]\] //')

  TOTAL=${#ALL_TASKS[@]}
  COMPLETED=0
  REMAINING=0
  REMAINING_TASKS=()
  COMPLETED_TASKS=()

  for task in "${ALL_TASKS[@]}"; do
    if grep -qxF "[DONE] $task" progress.txt 2>/dev/null; then
      COMPLETED=$((COMPLETED + 1))
      COMPLETED_TASKS+=("$task")
    else
      REMAINING=$((REMAINING + 1))
      REMAINING_TASKS+=("$task")
    fi
  done

  echo "Tasks: $TOTAL total, $COMPLETED completed, $REMAINING remaining"
  echo ""

  if [ ${#COMPLETED_TASKS[@]} -gt 0 ]; then
    echo "Completed:"
    for task in "${COMPLETED_TASKS[@]}"; do
      echo "  [x] $task"
    done
    echo ""
  fi

  if [ ${#REMAINING_TASKS[@]} -gt 0 ]; then
    echo "Remaining:"
    for task in "${REMAINING_TASKS[@]}"; do
      echo "  [ ] $task"
    done
  else
    echo "All tasks complete!"
  fi

  exit 0
fi

# --- dry-run subcommand ---
if [ "${1:-}" = "--dry-run" ]; then
  if [ ! -f "PRD.md" ]; then
    echo "Error: PRD.md not found." >&2
    exit 1
  fi

  mapfile -t ALL_TASKS < <(grep -E '^\- \[[ x]\] ' PRD.md | sed 's/^- \[[ x]\] //')

  for task in "${ALL_TASKS[@]}"; do
    if ! grep -qxF "[DONE] $task" progress.txt 2>/dev/null; then
      echo "Next task: $task"
      exit 0
    fi
  done

  echo "All tasks complete."
  exit 0
fi

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
  echo "Error: another instance of ralph.sh is already running (lockfile: $LOCKFILE). Aborting." >&2
  exit 1
fi
trap 'rm -f "$LOCKFILE"' EXIT

MAX=${1:-20}
MAX_RETRIES=${MAX_RETRIES:-3}
RALPH_MAX_STALLS=${RALPH_MAX_STALLS:-3}
RETRY_DELAY=${RALPH_RETRY_DELAY:-5}
CLAUDE_MODEL=${CLAUDE_MODEL:-}
RALPH_TIMEOUT=${RALPH_TIMEOUT:-}
RALPH_ALLOWED_TOOLS=${RALPH_ALLOWED_TOOLS:-"Edit,Write,Bash,Read,Glob,Grep"}
RALPH_BASE_BRANCH=${RALPH_BASE_BRANCH:-main}
RALPH_LOG_KEEP=${RALPH_LOG_KEEP:-50}

LOGS_DIR="logs"
mkdir -p "$LOGS_DIR"

# Rotate old log files: keep only the RALPH_LOG_KEEP most recent, delete the rest.
if [ "${RALPH_LOG_KEEP}" -gt 0 ]; then
  (cd "$LOGS_DIR" && ls -t | tail -n +"$((RALPH_LOG_KEEP + 1))" | xargs rm -f)
fi

RUN_LOG="$LOGS_DIR/run_$(date +%Y%m%d_%H%M%S).log"

CURRENT_ITER=0
STALL_COUNT=0

handle_signal() {
  local sig="$1"
  local msg="=== Received $sig — shutting down gracefully after iteration $CURRENT_ITER/$MAX === $(date '+%Y-%m-%d %H:%M:%S') ==="
  echo ""
  echo "$msg"
  echo "$msg" >> "$RUN_LOG"
  rm -f "$LOGS_DIR/claude_output_"*".tmp"
  exit 0
}

trap 'handle_signal SIGINT'  INT
trap 'handle_signal SIGTERM' TERM

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

run_claude() {
  local attempt=1
  local tmpfile="$LOGS_DIR/claude_output_$$.tmp"
  while [ $attempt -le $MAX_RETRIES ]; do
    # Build command as array to avoid shell injection from PROMPT content
    local CMD=(claude -p "$PROMPT" --allowedTools "$RALPH_ALLOWED_TOOLS" --verbose)
    if [ -n "$CLAUDE_MODEL" ]; then
      CMD+=(--model "$CLAUDE_MODEL")
    fi
    # Stream output to terminal in real-time while capturing it
    if [ -n "$RALPH_TIMEOUT" ]; then
      timeout "$RALPH_TIMEOUT" "${CMD[@]}" 2>&1 | tee "$tmpfile"
    else
      "${CMD[@]}" 2>&1 | tee "$tmpfile"
    fi
    local exit_code=${PIPESTATUS[0]}
    if [ "$exit_code" -eq 124 ]; then
      echo "Warning: Claude invocation timed out after ${RALPH_TIMEOUT}s (attempt $attempt/$MAX_RETRIES)" >&2
    fi
    if [ $exit_code -eq 0 ]; then
      OUTPUT=$(cat "$tmpfile")
      rm -f "$tmpfile"
      return 0
    fi
    echo "Warning: Claude CLI failed (attempt $attempt/$MAX_RETRIES, exit code $exit_code)" >&2
    if [ $attempt -lt $MAX_RETRIES ]; then
      BACKOFF=$(( RETRY_DELAY * (1 << (attempt - 1)) ))
      if [ "$BACKOFF" -gt 60 ]; then BACKOFF=60; fi
      echo "Retrying in ${BACKOFF}s..." >&2
      sleep "$BACKOFF"
    fi
    attempt=$((attempt + 1))
  done
  echo "Error: Claude CLI failed after $MAX_RETRIES attempts." >&2
  OUTPUT=$(cat "$tmpfile" 2>/dev/null)
  rm -f "$tmpfile"
  return 1
}

for i in $(seq 1 "$MAX"); do
  CURRENT_ITER=$i
  ITER_HEADER="=== Ralph iteration $i/$MAX === $(date '+%Y-%m-%d %H:%M:%S') ==="
  echo "$ITER_HEADER"
  echo "$ITER_HEADER" >> "$RUN_LOG"

  DONE_BEFORE=$(grep -c '^\[DONE\]' progress.txt 2>/dev/null | tail -1)
  DONE_BEFORE=${DONE_BEFORE:-0}

  OUTPUT=""
  if ! run_claude; then
    MSG="Skipping iteration $i due to repeated Claude CLI failures."
    echo "$MSG" >&2
    echo "$MSG" >> "$RUN_LOG"
    continue
  fi
  echo "$OUTPUT" >> "$RUN_LOG"

  DONE_AFTER=$(grep -c '^\[DONE\]' progress.txt 2>/dev/null | tail -1)
  DONE_AFTER=${DONE_AFTER:-0}
  if [ "$DONE_AFTER" -le "$DONE_BEFORE" ]; then
    STALL_COUNT=$((STALL_COUNT + 1))
    STALL_MSG="Warning: No progress detected in iteration $i (stall $STALL_COUNT/$RALPH_MAX_STALLS)."
    echo "$STALL_MSG" | tee -a "$RUN_LOG"
    if [ "$STALL_COUNT" -ge "$RALPH_MAX_STALLS" ]; then
      STALL_EXIT_MSG="Error: Ralph has stalled for $RALPH_MAX_STALLS consecutive iterations without progress. Exiting."
      echo "$STALL_EXIT_MSG" | tee -a "$RUN_LOG"
      exit 1
    fi
  else
    STALL_COUNT=0
  fi

  if git diff --quiet && git diff --cached --quiet; then
    echo "No changes to commit for iteration $i."
    echo "No changes to commit for iteration $i." >> "$RUN_LOG"
  else
    LAST_DONE=$(grep '^\[DONE\]' progress.txt 2>/dev/null | tail -1 | sed 's/^\[DONE\] //')
    if [ -n "$LAST_DONE" ]; then
      COMMIT_MSG="ralph: $LAST_DONE (iteration $i)"
    else
      COMMIT_MSG="ralph: completed task (iteration $i)"
    fi
    BRANCH_NAME="ralph/iter-${i}-$(date +%Y%m%d_%H%M%S)"
    git checkout -b "$BRANCH_NAME"
    git add -A
    if git commit -m "$(printf '%s\n\nCo-Authored-By: Ralph Wiggum <ralph@wiggum.bot>' "$COMMIT_MSG")"; then
      echo "Committed changes: $COMMIT_MSG" | tee -a "$RUN_LOG"
      if git remote get-url origin &>/dev/null; then
        if git push -u origin "$BRANCH_NAME"; then
          echo "Pushed branch $BRANCH_NAME to remote." | tee -a "$RUN_LOG"
          if command -v gh &>/dev/null; then
            if PR_URL=$(gh pr create --title "$COMMIT_MSG" --body "Automated PR from Ralph iteration $i." --base "$RALPH_BASE_BRANCH" 2>&1); then
              echo "Created PR: $PR_URL" | tee -a "$RUN_LOG"
              gh pr merge --squash --delete-branch "$PR_URL" 2>&1 | tee -a "$RUN_LOG" || echo "Warning: PR merge failed." | tee -a "$RUN_LOG"
            else
              echo "Warning: gh pr create failed: $PR_URL" | tee -a "$RUN_LOG"
            fi
          else
            echo "Warning: gh CLI not found, skipping PR creation." | tee -a "$RUN_LOG"
          fi
        else
          echo "Warning: git push failed for iteration $i." | tee -a "$RUN_LOG"
        fi
      else
        echo "Info: No remote 'origin' configured, skipping push for iteration $i." | tee -a "$RUN_LOG"
      fi
    else
      echo "Warning: git commit failed for iteration $i." | tee -a "$RUN_LOG"
    fi
    git checkout "$RALPH_BASE_BRANCH"
    git pull --ff-only origin "$RALPH_BASE_BRANCH" 2>/dev/null || true
  fi

  if echo "$OUTPUT" | grep -q "<promise>COMPLETE</promise>"; then
    DONE_MSG="=== All tasks complete after $i iteration(s). Generating new tasks... ==="
    echo ""
    echo "$DONE_MSG" | tee -a "$RUN_LOG"

    PLAN_PROMPT="Review the codebase in this directory. The project is a self-improving agentic loop called Ralph. All tasks in PRD.md have been completed (see progress.txt). Your job is to review the code for weaknesses, missing features, or further improvements, then REWRITE the Tasks section in PRD.md with a fresh list of at least 5 unchecked improvement tasks in the format '- [ ] task description'. Replace the existing task list entirely with the new one. Do not modify progress.txt or check off any boxes."

    PLAN_CMD=(claude -p "$PLAN_PROMPT" --allowedTools "$RALPH_ALLOWED_TOOLS" --verbose)
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
      echo "Warning: Planning call failed (attempt $PLAN_ATTEMPT/$MAX_RETRIES, exit code $PLAN_EXIT)" | tee -a "$RUN_LOG" >&2
      if [ $PLAN_ATTEMPT -lt $MAX_RETRIES ]; then
        BACKOFF=$(( RETRY_DELAY * (1 << (PLAN_ATTEMPT - 1)) ))
        if [ "$BACKOFF" -gt 60 ]; then BACKOFF=60; fi
        echo "Retrying planning call in ${BACKOFF}s..." >&2
        sleep "$BACKOFF"
      fi
      PLAN_ATTEMPT=$((PLAN_ATTEMPT + 1))
    done
    if [ "$PLAN_EXIT" -ne 0 ]; then
      echo "Warning: Planning call failed after $MAX_RETRIES attempts. Proceeding with archive/reset." | tee -a "$RUN_LOG" >&2
    fi

    # Archive completed progress entries and reset progress.txt for the new cycle.
    ARCHIVE_FILE="$LOGS_DIR/progress_archive_$(date +%Y%m%d_%H%M%S).txt"
    cp progress.txt "$ARCHIVE_FILE"
    printf "# Progress Tracker\n# Each completed task is logged here by the agent.\n# Format: [DONE] Task description\n" > progress.txt
    ARCHIVE_MSG="Archived progress.txt to $ARCHIVE_FILE and reset for new cycle."
    echo "$ARCHIVE_MSG" | tee -a "$RUN_LOG"

    if ! git diff --quiet || ! git diff --cached --quiet; then
      CYCLE_BRANCH="ralph/cycle-rewrite-$(date +%Y%m%d_%H%M%S)"
      git checkout -b "$CYCLE_BRANCH"
      git add -A
      if git commit -m "$(printf 'ralph: rewrite PRD.md tasks for next cycle (iteration %s)\n\nCo-Authored-By: Ralph Wiggum <ralph@wiggum.bot>' "$i")"; then
        echo "Committed new tasks." | tee -a "$RUN_LOG"
        if git remote get-url origin &>/dev/null; then
          if git push -u origin "$CYCLE_BRANCH"; then
            echo "Pushed branch $CYCLE_BRANCH to remote." | tee -a "$RUN_LOG"
            if command -v gh &>/dev/null; then
              if PR_URL=$(gh pr create --title "ralph: rewrite PRD.md tasks for next cycle" --body "Automated cycle rewrite from Ralph iteration $i." --base "$RALPH_BASE_BRANCH" 2>&1); then
                echo "Created PR: $PR_URL" | tee -a "$RUN_LOG"
                gh pr merge --squash --delete-branch "$PR_URL" 2>&1 | tee -a "$RUN_LOG" || echo "Warning: PR merge failed." | tee -a "$RUN_LOG"
              else
                echo "Warning: gh pr create failed: $PR_URL" | tee -a "$RUN_LOG"
              fi
            fi
          else
            echo "Warning: git push failed after task rewrite." | tee -a "$RUN_LOG"
          fi
        else
          echo "Info: No remote 'origin' configured, skipping push after task rewrite." | tee -a "$RUN_LOG"
        fi
      else
        echo "Warning: git commit failed after task rewrite." | tee -a "$RUN_LOG"
      fi
      git checkout "$RALPH_BASE_BRANCH"
      git pull --ff-only origin "$RALPH_BASE_BRANCH" 2>/dev/null || true
    fi

    continue
  fi
done

LIMIT_MSG="=== Reached max iterations ($MAX) without completion signal. ==="
echo "$LIMIT_MSG"
echo "$LIMIT_MSG" >> "$RUN_LOG"
