#!/usr/bin/env bash
# ralph-once.sh — Run a single Ralph iteration (one Claude session).
# Usage: ./ralph-once.sh

set -euo pipefail

CLAUDE_MODEL=${CLAUDE_MODEL:-}
RALPH_TIMEOUT=${RALPH_TIMEOUT:-}
MAX_RETRIES=${MAX_RETRIES:-3}
RETRY_DELAY=5
RALPH_MAIN_BRANCH=${RALPH_MAIN_BRANCH:-main}

LOGS_DIR="logs"
mkdir -p "$LOGS_DIR"
RUN_LOG="$LOGS_DIR/once_$(date +%Y%m%d_%H%M%S).log"

# --- pre-flight checks ---
for _bin in claude git node; do
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

# --- GitHub PR helpers ---

# Extract owner/repo from the origin remote URL (supports SSH and HTTPS GitHub remotes).
get_github_repo() {
  local remote_url
  remote_url=$(git remote get-url origin 2>/dev/null || echo "")
  echo "$remote_url" | sed 's|.*github\.com[:/]||' | sed 's|\.git$||'
}

# Commit staged+unstaged changes on a new branch, push, open a PR, merge it, then return to main.
# Usage: pr_commit_and_merge <branch> <commit_msg> [<logfile>]
pr_commit_and_merge() {
  local branch="$1"
  local msg="$2"
  local logfile="${3:-/dev/null}"
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local full_msg
  full_msg="$(printf '%s\n\nCo-authored-by: Ralph Wiggum <ralph@wiggum.bot>' "$msg")"

  git checkout -B "$branch"
  git add -A
  if git commit \
      --author "Kailash Gautham <kailash.gautham@gmail.com>" \
      -m "$full_msg"; then
    echo "Committed: $msg" | tee -a "$logfile"
    if git push -u origin "$branch"; then
      local github_repo
      github_repo=$(get_github_repo)
      if [ -n "$github_repo" ] && [ -n "${GH_TOKEN:-}" ]; then
        local pr_out pr_number
        pr_out=$(RALPH_GITHUB_REPO="$github_repo" node "$script_dir/ralph-github.js" \
          create-pr "$branch" "$RALPH_MAIN_BRANCH" "$msg" 2>&1)
        echo "$pr_out" | tee -a "$logfile"
        pr_number=$(echo "$pr_out" | grep -E '^[0-9]+$' | head -1)
        if [ -n "$pr_number" ]; then
          RALPH_GITHUB_REPO="$github_repo" node "$script_dir/ralph-github.js" \
            merge-pr "$pr_number" 2>&1 | tee -a "$logfile"
          echo "PR #$pr_number merged." | tee -a "$logfile"
        else
          echo "Warning: Could not determine PR number from create-pr output." >&2
        fi
      else
        echo "Warning: GH_TOKEN not set or origin is not a GitHub repo — skipping PR creation." >&2
      fi
    else
      echo "Warning: git push failed for branch $branch." >&2
    fi
    git checkout "$RALPH_MAIN_BRANCH"
    git pull
  else
    echo "Warning: git commit failed." >&2
    git checkout "$RALPH_MAIN_BRANCH"
  fi
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

# Build command as array to avoid shell injection from PROMPT content
CMD=(claude -p "$PROMPT" --allowedTools "Edit,Write,Bash,Read,Glob,Grep" --verbose)
if [ -n "$CLAUDE_MODEL" ]; then
  CMD+=(--model "$CLAUDE_MODEL")
fi

# Stream output to terminal in real-time while capturing it to a temp file
TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE" "$LOCKFILE"' EXIT

set +e
if [ -n "$RALPH_TIMEOUT" ]; then
  timeout "$RALPH_TIMEOUT" "${CMD[@]}" 2>&1 | tee "$TMPFILE"
else
  "${CMD[@]}" 2>&1 | tee "$TMPFILE"
fi
CLAUDE_EXIT=${PIPESTATUS[0]}
set -e

OUTPUT=$(cat "$TMPFILE")
echo "$OUTPUT" >> "$RUN_LOG"

if [ "$CLAUDE_EXIT" -eq 124 ]; then
  echo "Error: Claude invocation timed out after ${RALPH_TIMEOUT}s" >&2
  exit 124
fi
if [ "$CLAUDE_EXIT" -ne 0 ]; then
  echo "Error: Claude CLI exited with code $CLAUDE_EXIT" >&2
  exit "$CLAUDE_EXIT"
fi

if git diff --quiet && git diff --cached --quiet; then
  echo "No changes to commit." | tee -a "$RUN_LOG"
else
  LAST_DONE=$(grep '^\[DONE\]' progress.txt 2>/dev/null | tail -1 | sed 's/^\[DONE\] //')
  if [ -n "$LAST_DONE" ]; then
    COMMIT_MSG="ralph: ${LAST_DONE} (single iteration)"
  else
    COMMIT_MSG="ralph: completed task (single iteration)"
  fi
  ITER_BRANCH="ralph/once-$(date +%Y%m%d_%H%M%S)"
  pr_commit_and_merge "$ITER_BRANCH" "$COMMIT_MSG" "$RUN_LOG"
fi

if echo "$OUTPUT" | grep -q "<promise>COMPLETE</promise>"; then
  echo ""
  echo "=== All tasks complete. Generating new tasks... ===" | tee -a "$RUN_LOG"

  PLAN_PROMPT="Review the codebase in this directory. The project is a self-improving agentic loop called Ralph. All tasks in PRD.md have been completed (see progress.txt). Your job is to review the code for weaknesses, missing features, or further improvements, then REWRITE the Tasks section in PRD.md with a fresh list of at least 5 unchecked improvement tasks in the format '- [ ] task description'. Replace the existing task list entirely with the new one. Do not modify progress.txt or check off any boxes."

  PLAN_CMD=(claude -p "$PLAN_PROMPT" --allowedTools "Edit,Write,Bash,Read,Glob,Grep")
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
      echo "Retrying planning call in ${RETRY_DELAY}s..." >&2
      sleep $RETRY_DELAY
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
    REPLAN_BRANCH="ralph/replan-$(date +%Y%m%d_%H%M%S)"
    pr_commit_and_merge "$REPLAN_BRANCH" "ralph: rewrite PRD.md tasks for next cycle (single iteration)" "$RUN_LOG"
  fi

  exit 0
fi
