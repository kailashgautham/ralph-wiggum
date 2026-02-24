#!/usr/bin/env bash
# ralph-lib.sh — Shared helper functions for Ralph scripts.
# Source this file from ralph.sh and ralph-once.sh; do not execute directly.

# Default planning prompt used when RALPH_PLAN_PROMPT is not set in the environment.
RALPH_DEFAULT_PLAN_PROMPT="Review the codebase in this directory. The project is a self-improving agentic loop called Ralph. All tasks in PRD.md have been completed (see progress.txt). Your job is to review the code for weaknesses, missing features, or further improvements, then REWRITE the Tasks section in PRD.md with a fresh list of at least 5 unchecked improvement tasks in the format '- [ ] task description'. Replace the existing task list entirely with the new one. Do not modify progress.txt or check off any boxes."

# _ralph_fire_hook EXIT_REASON
# If RALPH_COMPLETE_HOOK is set, exports RALPH_EXIT_REASON=EXIT_REASON and
# runs the hook via eval. Called immediately before each terminal exit.
_ralph_fire_hook() {
  if [ -n "${RALPH_COMPLETE_HOOK:-}" ]; then
    export RALPH_EXIT_REASON="$1"
    eval "$RALPH_COMPLETE_HOOK"
  fi
}

# _ralph_is_credit_error OUTPUT
# Returns 0 if OUTPUT appears to indicate a credit/quota exhaustion error
# from the Claude CLI, 1 otherwise. Used to trigger a long retry delay
# instead of failing fast after the normal MAX_RETRIES attempts.
_ralph_is_credit_error() {
  local output="$1"
  echo "$output" | grep -qiE "credit balance|insufficient credit|out of credit|usage limit|quota exceed|payment required|402 Payment|billing"
}

# validate_int VAR_NAME
# Checks that the named variable holds a positive integer value.
# Prints an error and exits 1 if it does not.
validate_int() {
  local var_name="$1"
  local value="${!var_name}"
  if ! [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: $var_name must be a positive integer (got '$value')" >&2
    exit 1
  fi
}

# validate_non_negative_int VAR_NAME
# Checks that the named variable holds a non-negative integer value (0 or greater).
# Prints an error and exits 1 if it does not.
validate_non_negative_int() {
  local var_name="$1"
  local value="${!var_name}"
  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    echo "Error: $var_name must be a non-negative integer (got '$value')" >&2
    exit 1
  fi
}

# _ralph_log MSG
# Prints MSG to stdout. If RUN_LOG is set and non-empty, also appends to it.
_ralph_log() {
  if [ -n "${RUN_LOG:-}" ]; then
    echo "$1" | tee -a "$RUN_LOG"
  else
    echo "$1"
  fi
}

# ralph_commit_push_pr BRANCH_PREFIX COMMIT_MSG PR_BODY
# Checks out a new timestamped branch derived from BRANCH_PREFIX, commits all
# changes with COMMIT_MSG, and (when a remote and the gh CLI are available)
# pushes, creates a PR titled COMMIT_MSG with body PR_BODY, and squash-merges
# it. After the PR is merged (or if there is no remote), checks out
# RALPH_BASE_BRANCH and fast-forward pulls.
#
# If RALPH_NO_PR is set to any non-empty value, PR creation and merge are
# skipped; the branch is pushed and left on the remote for manual review.
#
# Globals used: RALPH_BASE_BRANCH (required), RALPH_NO_PR (optional),
# RUN_LOG (optional — messages are also tee'd to it when set).
ralph_commit_push_pr() {
  local branch_prefix="$1"
  local commit_msg="$2"
  local pr_body="${3:-Automated PR from Ralph.}"
  local branch_name="${branch_prefix}-$(date +%Y%m%d_%H%M%S)"

  git checkout -b "$branch_name"
  git add -A
  if git commit -m "$(printf '%s\n\nCo-Authored-By: Ralph Wiggum <ralph@wiggum.bot>' "$commit_msg")"; then
    _ralph_log "Committed changes: $commit_msg"
    if git remote get-url origin &>/dev/null; then
      if git push -u origin "$branch_name"; then
        _ralph_log "Pushed branch $branch_name to remote."
        if [ -n "${RALPH_NO_PR:-}" ]; then
          _ralph_log "RALPH_NO_PR is set; skipping PR creation. Branch '$branch_name' left on remote for manual review."
        elif command -v gh &>/dev/null; then
          local pr_url
          if pr_url=$(gh pr create --title "$commit_msg" --body "$pr_body" --base "$RALPH_BASE_BRANCH" 2>&1); then
            _ralph_log "Created PR: $pr_url"
            if [ -n "${RUN_LOG:-}" ]; then
              gh pr merge --squash --delete-branch "$pr_url" 2>&1 | tee -a "$RUN_LOG" || _ralph_log "Warning: PR merge failed."
            else
              gh pr merge --squash --delete-branch "$pr_url" 2>&1 || echo "Warning: PR merge failed." >&2
            fi
          else
            _ralph_log "Warning: gh pr create failed: $pr_url"
          fi
        else
          _ralph_log "Warning: gh CLI not found, skipping PR creation."
        fi
      else
        _ralph_log "Warning: git push failed."
      fi
    else
      _ralph_log "Info: No remote 'origin' configured, skipping push."
    fi
  else
    _ralph_log "Warning: git commit failed."
  fi
  git checkout "$RALPH_BASE_BRANCH"
  git pull --ff-only origin "$RALPH_BASE_BRANCH" 2>/dev/null || true
}

# ralph_show_status
# Prints a summary of completed and remaining tasks from PRD.md and progress.txt.
# Exits 0 on success, 1 if PRD.md is not found.
ralph_show_status() {
  echo "=== Ralph Status ==="

  if [ ! -f "PRD.md" ]; then
    echo "Error: PRD.md not found." >&2
    exit 1
  fi

  # Extract task descriptions from PRD.md (both unchecked and checked boxes)
  local -a ALL_TASKS
  mapfile -t ALL_TASKS < <(grep -E '^\- \[[ x]\] ' PRD.md | sed 's/^- \[[ x]\] //')

  local TOTAL=${#ALL_TASKS[@]}
  local COMPLETED=0
  local REMAINING=0
  local -a REMAINING_TASKS=()
  local -a COMPLETED_TASKS=()

  local task
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
}

# ralph_next_task
# Prints the next uncompleted task from PRD.md and exits 0.
# If all tasks are complete, prints "All tasks complete." and exits 0.
# Exits 1 if PRD.md is not found.
ralph_next_task() {
  if [ ! -f "PRD.md" ]; then
    echo "Error: PRD.md not found." >&2
    exit 1
  fi

  local -a ALL_TASKS
  mapfile -t ALL_TASKS < <(grep -E '^\- \[[ x]\] ' PRD.md | sed 's/^- \[[ x]\] //')

  local task
  for task in "${ALL_TASKS[@]}"; do
    if ! grep -qxF "[DONE] $task" progress.txt 2>/dev/null; then
      echo "Next task: $task"
      exit 0
    fi
  done

  echo "All tasks complete."
  exit 0
}

# _ralph_invoke_claude_with_retry CMD_ARRAY_NAME CAPTURE_OUTPUT
# Internal shared helper: runs the claude command with retry/backoff logic,
# including the credit-exhaustion branch (1-hour pause + indefinite retry).
#   CMD_ARRAY_NAME   name of a bash array variable holding the command + args
#   CAPTURE_OUTPUT   "yes" → tee output to a tmp file, then set the global
#                            OUTPUT variable from that file after the loop;
#                            does NOT additionally pipe to RUN_LOG
#                    "no"  → tee output to a tmp file AND additionally pipe to
#                            ${RUN_LOG:-/dev/null}
# Globals used: MAX_RETRIES, RETRY_DELAY, RALPH_TIMEOUT, LOGS_DIR, RUN_LOG
# Sets global OUTPUT (when CAPTURE_OUTPUT="yes"). Returns the final exit code.
_ralph_invoke_claude_with_retry() {
  local cmd_array_name="$1"
  local capture_output="$2"
  local -n _cmd_ref="$cmd_array_name"
  local max_retries="${MAX_RETRIES:-3}"
  local retry_delay="${RETRY_DELAY:-5}"
  local tmpfile
  tmpfile=$(mktemp "${LOGS_DIR:-/tmp}/claude_XXXXXX")
  local attempt=1
  local exit_code=1
  while [ $attempt -le $max_retries ]; do
    set +e
    if [ -n "${RALPH_TIMEOUT:-}" ]; then
      if [ "$capture_output" = "yes" ]; then
        timeout "$RALPH_TIMEOUT" "${_cmd_ref[@]}" 2>&1 | tee "$tmpfile"
      else
        timeout "$RALPH_TIMEOUT" "${_cmd_ref[@]}" 2>&1 | tee "$tmpfile" | tee -a "${RUN_LOG:-/dev/null}"
      fi
    else
      if [ "$capture_output" = "yes" ]; then
        "${_cmd_ref[@]}" 2>&1 | tee "$tmpfile"
      else
        "${_cmd_ref[@]}" 2>&1 | tee "$tmpfile" | tee -a "${RUN_LOG:-/dev/null}"
      fi
    fi
    exit_code=${PIPESTATUS[0]}
    set -e
    if [ "$exit_code" -eq 124 ]; then
      echo "Warning: Claude invocation timed out after ${RALPH_TIMEOUT}s (attempt $attempt/$max_retries)" >&2
    fi
    if [ "$exit_code" -eq 0 ]; then
      break
    fi
    # Credit exhaustion: pause for an hour and retry indefinitely.
    if _ralph_is_credit_error "$(cat "$tmpfile")"; then
      echo "Warning: Credits exhausted. Waiting 1 hour before retry..." >&2
      sleep 3600
      continue
    fi
    echo "Warning: Claude CLI failed (attempt $attempt/$max_retries, exit code $exit_code)" >&2
    if [ $attempt -lt $max_retries ]; then
      local backoff=$(( retry_delay * (1 << (attempt - 1)) ))
      if [ "$backoff" -gt 60 ]; then backoff=60; fi
      echo "Retrying in ${backoff}s..." >&2
      sleep "$backoff"
    fi
    attempt=$((attempt + 1))
  done
  if [ "$capture_output" = "yes" ]; then
    OUTPUT=$(cat "$tmpfile")
  fi
  rm -f "$tmpfile"
  return "$exit_code"
}

# ralph_run_main_call PROMPT
# Invokes Claude with PROMPT for the main task execution phase.
# Streams output to the terminal in real-time and captures it to a temp file.
# Retries up to MAX_RETRIES times with exponential backoff. On success, sets
# the global OUTPUT variable and returns 0. On failure, sets OUTPUT to whatever
# was captured, prints an error message, and returns the last exit code (124 if
# timed out).
#
# Globals used: CLAUDE_MODEL, RALPH_TIMEOUT, RALPH_ALLOWED_TOOLS,
#               MAX_RETRIES, RETRY_DELAY, LOGS_DIR, OUTPUT (set on return)
ralph_run_main_call() {
  local prompt="$1"
  local cmd=(claude -p "$prompt" --allowedTools "${RALPH_ALLOWED_TOOLS:-Edit,Write,Bash,Read,Glob,Grep}" --verbose)
  if [ -n "${CLAUDE_MODEL:-}" ]; then
    cmd+=(--model "$CLAUDE_MODEL")
  fi
  local exit_code
  _ralph_invoke_claude_with_retry cmd "yes"
  exit_code=$?
  if [ "$exit_code" -eq 124 ]; then
    echo "Error: Claude invocation timed out after ${RALPH_TIMEOUT}s" >&2
    return 124
  fi
  if [ "$exit_code" -ne 0 ]; then
    echo "Error: Claude CLI failed after ${MAX_RETRIES:-3} attempts (exit code $exit_code)." >&2
    return "$exit_code"
  fi
  return 0
}

# ralph_handle_complete ITER_LABEL
# Handles the <promise>COMPLETE</promise> signal: logs a completion message,
# invokes the planning call to generate a new task list, archives progress.txt
# to logs/, resets progress.txt to its header, and (when git is available and
# changes exist) commits via ralph_commit_push_pr.
#
# ITER_LABEL is a short string describing the current iteration context, used
# in the log message and commit message (e.g. "iteration 3" or "single
# iteration").
#
# Globals used: RALPH_NO_GIT (optional), LOGS_DIR (required), RUN_LOG
#               (optional), RALPH_BASE_BRANCH (required for git ops)
ralph_handle_complete() {
  local iter_label="$1"
  local done_msg="=== All tasks complete ($iter_label). Generating new tasks... ==="
  echo ""
  _ralph_log "$done_msg"

  local plan_prompt="${RALPH_PLAN_PROMPT:-$RALPH_DEFAULT_PLAN_PROMPT}"

  ralph_run_planning_call "$plan_prompt"

  # Archive completed progress entries and reset progress.txt for the new cycle.
  local archive_file
  archive_file="$LOGS_DIR/progress_archive_$(date +%Y%m%d_%H%M%S).txt"
  cp progress.txt "$archive_file"
  printf "# Progress Tracker\n# Each completed task is logged here by the agent.\n# Format: [DONE] Task description\n" > progress.txt
  _ralph_log "Archived progress.txt to $archive_file and reset for new cycle."

  if [ -z "${RALPH_NO_GIT:-}" ] && { ! git diff --quiet || ! git diff --cached --quiet; }; then
    ralph_commit_push_pr "ralph/cycle-rewrite" "ralph: rewrite PRD.md tasks for next cycle ($iter_label)" "Automated cycle rewrite from Ralph $iter_label."
  fi
}

# ralph_run_planning_call PROMPT
# Invokes Claude with PROMPT for the planning/task-generation phase.
# Retries up to MAX_RETRIES times with exponential backoff, logging output to
# RUN_LOG (when set). Includes --verbose so planning-phase tool calls are
# visible. Logs a warning and returns 1 if all attempts fail (non-fatal:
# callers are expected to proceed with archive/reset regardless).
#
# Globals used: CLAUDE_MODEL, RALPH_TIMEOUT, RALPH_ALLOWED_TOOLS,
#               MAX_RETRIES, RETRY_DELAY, RUN_LOG
ralph_run_planning_call() {
  local prompt="$1"
  local plan_cmd=(claude -p "$prompt" --allowedTools "${RALPH_ALLOWED_TOOLS:-Edit,Write,Bash,Read,Glob,Grep}" --verbose)
  if [ -n "${CLAUDE_MODEL:-}" ]; then
    plan_cmd+=(--model "$CLAUDE_MODEL")
  fi
  local exit_code
  _ralph_invoke_claude_with_retry plan_cmd "no"
  exit_code=$?
  if [ "$exit_code" -eq 0 ]; then
    return 0
  fi
  echo "Warning: Planning call failed after ${MAX_RETRIES:-3} attempts. Proceeding with archive/reset." | tee -a "${RUN_LOG:-/dev/null}" >&2
  return 1
}
