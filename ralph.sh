#!/usr/bin/env bash
# ralph.sh — Automated Ralph Loop. Runs Claude in a fresh context each iteration.
# Usage: ./ralph.sh [max_iterations]

set -uo pipefail

source "$(dirname "$0")/ralph-lib.sh"

# --- help subcommand ---
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  cat <<'EOF'
Usage: ./ralph.sh [SUBCOMMAND | max_iterations]

Automated Ralph loop: runs Claude in a fresh context each iteration until
all PRD.md tasks are complete or the iteration limit is reached.

Subcommands:
  status          Show completed/remaining task counts and task list
  --dry-run       Print the next task without running anything
  --help, -h      Show this help and exit

Arguments:
  max_iterations  Maximum number of iterations to run (default: 20)

Environment variables:
  CLAUDE_MODEL          Claude model to use (default: claude default)
  RALPH_BASE_BRANCH     Git base branch for PRs (default: main)
  RALPH_MAX_STALLS      Consecutive no-progress iterations before abort (default: 3)
  RALPH_TIMEOUT         Per-iteration timeout in seconds (default: none)
  RALPH_LOG_KEEP        Number of log files to retain (default: 50)
  MAX_RETRIES           Retry attempts on Claude CLI failure (default: 3)
  RALPH_RETRY_DELAY     Base delay in seconds between retries (default: 5)
  RALPH_ALLOWED_TOOLS   Comma-separated allowed Claude tools
                        (default: Edit,Write,Bash,Read,Glob,Grep)
  RALPH_NO_GIT          Skip all git operations (diff check, commit, push,
                        PR creation) when set to any non-empty value
  RALPH_NO_PR           If non-empty, skip PR creation and leave the branch
                        on the remote for manual review
  RALPH_PLAN_PROMPT     Override the planning prompt used when all tasks are
                        complete (default: built-in review-and-rewrite prompt)
  RALPH_COMPLETE_HOOK   Shell command executed (via eval) immediately before
                        ralph.sh exits via any terminal path. RALPH_EXIT_REASON
                        is exported as "complete" (all tasks done), "stall"
                        (stall limit reached), or "max_iterations" (loop limit
                        reached). Useful for notifications or cleanup.

Examples:
  ./ralph.sh                  # Run up to 20 iterations
  ./ralph.sh 10               # Run up to 10 iterations
  ./ralph.sh status           # Show task status
  RALPH_MAX_STALLS=5 ./ralph.sh 30
EOF
  exit 0
fi

# --- status subcommand ---
if [ "${1:-}" = "status" ]; then
  ralph_show_status
fi

# --- dry-run subcommand ---
if [ "${1:-}" = "--dry-run" ]; then
  ralph_next_task
fi

# --- pre-flight checks ---
RALPH_NO_GIT=${RALPH_NO_GIT:-}
_required_bins=(claude)
if [ -z "$RALPH_NO_GIT" ]; then
  _required_bins+=(git)
fi
for _bin in "${_required_bins[@]}"; do
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

validate_int MAX
validate_int MAX_RETRIES
validate_int RALPH_MAX_STALLS
validate_non_negative_int RALPH_LOG_KEEP
if [ -n "$RALPH_TIMEOUT" ]; then validate_int RALPH_TIMEOUT; fi

LOGS_DIR="logs"
mkdir -p "$LOGS_DIR"

# Rotate old log files: keep only the RALPH_LOG_KEEP most recent, delete the rest.
if [ "${RALPH_LOG_KEEP}" -gt 0 ]; then
  mapfile -t _log_files < <(ls -t "$LOGS_DIR")
  if [ "${#_log_files[@]}" -gt "$RALPH_LOG_KEEP" ]; then
    for _log_file in "${_log_files[@]:$RALPH_LOG_KEEP}"; do
      rm -f "$LOGS_DIR/$_log_file"
    done
  fi
  unset _log_files _log_file
fi

RUN_LOG="$LOGS_DIR/run_$(date +%Y%m%d_%H%M%S).log"

START_TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
START_TIME=$(date +%s)

CURRENT_ITER=0
STALL_COUNT=0

# _ralph_fire_hook EXIT_REASON
# If RALPH_COMPLETE_HOOK is set, exports RALPH_EXIT_REASON=EXIT_REASON and
# runs the hook via eval. Called immediately before each terminal exit.
_ralph_fire_hook() {
  if [ -n "${RALPH_COMPLETE_HOOK:-}" ]; then
    export RALPH_EXIT_REASON="$1"
    eval "$RALPH_COMPLETE_HOOK"
  fi
}

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

print_run_summary() {
  local exit_path="$1"
  local end_timestamp end_time elapsed done_count
  end_timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  end_time=$(date +%s)
  elapsed=$(( end_time - START_TIME ))
  done_count=$(grep -c '^\[DONE\]' progress.txt 2>/dev/null) || done_count=0
  local summary
  summary="=== Run summary | Exit: $exit_path | Start: $START_TIMESTAMP | End: $end_timestamp | Elapsed: ${elapsed}s | Iterations: $CURRENT_ITER/$MAX | Tasks completed: $done_count ==="
  echo ""
  echo "$summary"
  echo "$summary" >> "$RUN_LOG"
}

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

for i in $(seq 1 "$MAX"); do
  CURRENT_ITER=$i
  ITER_HEADER="=== Ralph iteration $i/$MAX === $(date '+%Y-%m-%d %H:%M:%S') ==="
  echo "$ITER_HEADER"
  echo "$ITER_HEADER" >> "$RUN_LOG"

  DONE_BEFORE=$(grep -c '^\[DONE\]' progress.txt 2>/dev/null | tail -1)
  DONE_BEFORE=${DONE_BEFORE:-0}

  OUTPUT=""
  if ! ralph_run_main_call "$PROMPT"; then
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
      print_run_summary "stall limit reached"
      _ralph_fire_hook "stall"
      exit 1
    fi
  else
    STALL_COUNT=0
  fi

  if [ -n "$RALPH_NO_GIT" ]; then
    echo "Skipping git operations (RALPH_NO_GIT is set)."
    echo "Skipping git operations (RALPH_NO_GIT is set)." >> "$RUN_LOG"
  elif git diff --quiet && git diff --cached --quiet; then
    echo "No changes to commit for iteration $i."
    echo "No changes to commit for iteration $i." >> "$RUN_LOG"
  else
    LAST_DONE=$(grep '^\[DONE\]' progress.txt 2>/dev/null | tail -1 | sed 's/^\[DONE\] //')
    if [ -n "$LAST_DONE" ]; then
      COMMIT_MSG="ralph: $LAST_DONE (iteration $i)"
    else
      COMMIT_MSG="ralph: completed task (iteration $i)"
    fi
    ralph_commit_push_pr "ralph/iter-${i}" "$COMMIT_MSG" "Automated PR from Ralph iteration $i."
  fi

  if echo "$OUTPUT" | grep -q "<promise>COMPLETE</promise>"; then
    print_run_summary "all tasks complete"
    _ralph_fire_hook "complete"
    ralph_handle_complete "iteration $i"
    continue
  fi
done

print_run_summary "max iterations reached"
LIMIT_MSG="=== Reached max iterations ($MAX) without completion signal. ==="
echo "$LIMIT_MSG"
echo "$LIMIT_MSG" >> "$RUN_LOG"
_ralph_fire_hook "max_iterations"
