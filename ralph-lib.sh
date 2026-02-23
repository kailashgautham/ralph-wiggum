#!/usr/bin/env bash
# ralph-lib.sh — Shared helper functions for Ralph scripts.
# Source this file from ralph.sh and ralph-once.sh; do not execute directly.

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
# Globals used: RALPH_BASE_BRANCH (required), RUN_LOG (optional — messages are
# also tee'd to it when set).
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
        if command -v gh &>/dev/null; then
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
