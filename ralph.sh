#!/usr/bin/env bash
# ralph.sh — Automated Ralph Loop. Runs Claude in a fresh context each iteration.
# Usage: ./ralph.sh [max_iterations]

set -uo pipefail

MAX=${1:-20}
MAX_RETRIES=3
RETRY_DELAY=5

LOGS_DIR="logs"
mkdir -p "$LOGS_DIR"
RUN_LOG="$LOGS_DIR/run_$(date +%Y%m%d_%H%M%S).log"

PROMPT="You are working on a software project. Read PRD.md for the full plan and progress.txt for completed tasks.
Pick the next uncompleted task from PRD.md, implement it, then append a line to progress.txt in the format:
  [DONE] <task description>
When ALL tasks in PRD.md are complete, output the token: <promise>COMPLETE</promise>"

run_claude() {
  local attempt=1
  while [ $attempt -le $MAX_RETRIES ]; do
    OUTPUT=$(claude -p "$PROMPT" --allowedTools "Edit,Write,Bash,Read,Glob,Grep" 2>&1)
    local exit_code=$?
    if [ $exit_code -eq 0 ]; then
      echo "$OUTPUT"
      return 0
    fi
    echo "Warning: Claude CLI failed (attempt $attempt/$MAX_RETRIES, exit code $exit_code)" >&2
    if [ $attempt -lt $MAX_RETRIES ]; then
      echo "Retrying in ${RETRY_DELAY}s..." >&2
      sleep $RETRY_DELAY
    fi
    attempt=$((attempt + 1))
  done
  echo "Error: Claude CLI failed after $MAX_RETRIES attempts." >&2
  return 1
}

for i in $(seq 1 "$MAX"); do
  ITER_HEADER="=== Ralph iteration $i/$MAX === $(date '+%Y-%m-%d %H:%M:%S') ==="
  echo "$ITER_HEADER"
  echo "$ITER_HEADER" >> "$RUN_LOG"

  if ! OUTPUT=$(run_claude); then
    MSG="Skipping iteration $i due to repeated Claude CLI failures."
    echo "$MSG" >&2
    echo "$MSG" >> "$RUN_LOG"
    continue
  fi
  echo "$OUTPUT"
  echo "$OUTPUT" >> "$RUN_LOG"

  if echo "$OUTPUT" | grep -q "<promise>COMPLETE</promise>"; then
    DONE_MSG="=== All tasks complete after $i iteration(s). ==="
    echo ""
    echo "$DONE_MSG"
    echo "$DONE_MSG" >> "$RUN_LOG"
    exit 0
  fi
done

LIMIT_MSG="=== Reached max iterations ($MAX) without completion signal. ==="
echo "$LIMIT_MSG"
echo "$LIMIT_MSG" >> "$RUN_LOG"
