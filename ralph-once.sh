#!/usr/bin/env bash
# ralph-once.sh — Run a single Ralph iteration (one Claude session).
# Usage: ./ralph-once.sh

set -euo pipefail

# --- help flag ---
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  cat <<'EOF'
Usage: ./ralph-once.sh [SUBCOMMAND]

Run a single Ralph iteration: invokes Claude once, commits any changes,
and exits. Useful for manual step-through of the Ralph loop.

Subcommands:
  status          Show completed/remaining task counts and task list
  --dry-run       Print the next task without running anything
  --help, -h      Show this help and exit

Environment variables:
  CLAUDE_MODEL          Claude model to use (default: claude default)
  RALPH_BASE_BRANCH     Git base branch for PRs (default: main)
  RALPH_TIMEOUT         Timeout in seconds for the Claude invocation (default: none)
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
                        ralph-once.sh exits via its terminal path. RALPH_EXIT_REASON
                        is exported as "complete" (all tasks done). Useful for
                        notifications or cleanup.

Examples:
  ./ralph-once.sh
  ./ralph-once.sh status
  ./ralph-once.sh --dry-run
  CLAUDE_MODEL=claude-opus-4-5 ./ralph-once.sh
  RALPH_TIMEOUT=300 ./ralph-once.sh
EOF
  exit 0
fi

source "$(dirname "$0")/ralph-lib.sh"

# --- status subcommand ---
if [ "${1:-}" = "status" ]; then
  ralph_show_status
fi

# --- dry-run subcommand ---
if [ "${1:-}" = "--dry-run" ]; then
  ralph_next_task
fi

CLAUDE_MODEL=${CLAUDE_MODEL:-}
RALPH_TIMEOUT=${RALPH_TIMEOUT:-}
MAX_RETRIES=${MAX_RETRIES:-3}
RETRY_DELAY=${RALPH_RETRY_DELAY:-5}
RALPH_ALLOWED_TOOLS=${RALPH_ALLOWED_TOOLS:-"Edit,Write,Bash,Read,Glob,Grep"}
RALPH_BASE_BRANCH=${RALPH_BASE_BRANCH:-main}
RALPH_NO_GIT=${RALPH_NO_GIT:-}

validate_int MAX_RETRIES
if [ -n "$RALPH_TIMEOUT" ]; then validate_int RALPH_TIMEOUT; fi

LOGS_DIR="logs"
mkdir -p "$LOGS_DIR"
RUN_LOG="$LOGS_DIR/once_$(date +%Y%m%d_%H%M%S).log"

# --- pre-flight checks ---
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
  echo "Error: another instance of ralph is already running (lockfile: $LOCKFILE). Aborting." >&2
  exit 1
fi
trap 'rm -f "$LOCKFILE"' EXIT

RUN_HEADER="=== Ralph single iteration === $(date '+%Y-%m-%d %H:%M:%S') ==="
echo "$RUN_HEADER" | tee -a "$RUN_LOG"

if [ -f "prompt.txt" ]; then
  PROMPT=$(cat prompt.txt)
  echo "Using prompt from prompt.txt"
else
  PROMPT="${RALPH_DEFAULT_PROMPT}"
fi

OUTPUT=""
MAIN_EXIT=0
ralph_run_main_call "$PROMPT" || MAIN_EXIT=$?
echo "$OUTPUT" >> "$RUN_LOG"
if [ "$MAIN_EXIT" -ne 0 ]; then
  exit "$MAIN_EXIT"
fi

if [ -n "$RALPH_NO_GIT" ]; then
  echo "Skipping git operations (RALPH_NO_GIT is set)."
elif git diff --quiet && git diff --cached --quiet; then
  echo "No changes to commit."
else
  LAST_DONE=$(grep '^\[DONE\]' progress.txt 2>/dev/null | tail -1 | sed 's/^\[DONE\] //')
  if [ -n "$LAST_DONE" ]; then
    COMMIT_MSG="ralph: ${LAST_DONE} (single iteration)"
  else
    COMMIT_MSG="ralph: completed task (single iteration)"
  fi
  ralph_commit_push_pr "ralph/once" "$COMMIT_MSG" "Automated PR from Ralph single iteration."
fi

if echo "$OUTPUT" | grep -q "<promise>COMPLETE</promise>"; then
  _ralph_fire_hook "complete"
  ralph_handle_complete "single iteration"
  exit 0
fi
