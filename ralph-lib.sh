#!/usr/bin/env bash
# ralph-lib.sh — Shared helper functions for Ralph scripts.
# Source this file from ralph.sh and ralph-once.sh; do not execute directly.

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
  local max_retries="${MAX_RETRIES:-3}"
  local retry_delay="${RETRY_DELAY:-5}"
  local cmd=(claude -p "$prompt" --allowedTools "${RALPH_ALLOWED_TOOLS:-Edit,Write,Bash,Read,Glob,Grep}" --verbose)
  if [ -n "${CLAUDE_MODEL:-}" ]; then
    cmd+=(--model "$CLAUDE_MODEL")
  fi
  local tmpfile
  tmpfile=$(mktemp "${LOGS_DIR:-/tmp}/claude_main_XXXXXX")
  local attempt=1
  local exit_code=1
  while [ $attempt -le $max_retries ]; do
    set +e
    if [ -n "${RALPH_TIMEOUT:-}" ]; then
      timeout "$RALPH_TIMEOUT" "${cmd[@]}" 2>&1 | tee "$tmpfile"
    else
      "${cmd[@]}" 2>&1 | tee "$tmpfile"
    fi
    exit_code=${PIPESTATUS[0]}
    set -e
    if [ "$exit_code" -eq 124 ]; then
      echo "Warning: Claude invocation timed out after ${RALPH_TIMEOUT}s (attempt $attempt/$max_retries)" >&2
    fi
    if [ "$exit_code" -eq 0 ]; then
      break
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
  OUTPUT=$(cat "$tmpfile")
  rm -f "$tmpfile"
  if [ "$exit_code" -eq 124 ]; then
    echo "Error: Claude invocation timed out after ${RALPH_TIMEOUT}s" >&2
    return 124
  fi
  if [ "$exit_code" -ne 0 ]; then
    echo "Error: Claude CLI failed after $max_retries attempts (exit code $exit_code)." >&2
    return "$exit_code"
  fi
  return 0
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
  local max_retries="${MAX_RETRIES:-3}"
  local retry_delay="${RETRY_DELAY:-5}"
  local plan_cmd=(claude -p "$prompt" --allowedTools "${RALPH_ALLOWED_TOOLS:-Edit,Write,Bash,Read,Glob,Grep}" --verbose)
  if [ -n "${CLAUDE_MODEL:-}" ]; then
    plan_cmd+=(--model "$CLAUDE_MODEL")
  fi
  local attempt=1
  local exit_code=1
  while [ $attempt -le $max_retries ]; do
    if [ -n "${RALPH_TIMEOUT:-}" ]; then
      timeout "$RALPH_TIMEOUT" "${plan_cmd[@]}" 2>&1 | tee -a "${RUN_LOG:-/dev/null}"
    else
      "${plan_cmd[@]}" 2>&1 | tee -a "${RUN_LOG:-/dev/null}"
    fi
    exit_code=${PIPESTATUS[0]}
    if [ "$exit_code" -eq 0 ]; then
      return 0
    fi
    echo "Warning: Planning call failed (attempt $attempt/$max_retries, exit code $exit_code)" | tee -a "${RUN_LOG:-/dev/null}" >&2
    if [ $attempt -lt $max_retries ]; then
      local backoff=$(( retry_delay * (1 << (attempt - 1)) ))
      if [ "$backoff" -gt 60 ]; then backoff=60; fi
      echo "Retrying planning call in ${backoff}s..." >&2
      sleep "$backoff"
    fi
    attempt=$((attempt + 1))
  done
  echo "Warning: Planning call failed after $max_retries attempts. Proceeding with archive/reset." | tee -a "${RUN_LOG:-/dev/null}" >&2
  return 1
}
