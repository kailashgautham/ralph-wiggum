#!/usr/bin/env bash
# ralph.sh — Automated Ralph Loop. Runs Claude in a fresh context each iteration.
# Usage: ./ralph.sh [max_iterations]

set -euo pipefail

MAX=${1:-20}

PROMPT="You are working on a software project. Read PRD.md for the full plan and progress.txt for completed tasks.
Pick the next uncompleted task from PRD.md, implement it, then append a line to progress.txt in the format:
  [DONE] <task description>
When ALL tasks in PRD.md are complete, output the token: <promise>COMPLETE</promise>"

for i in $(seq 1 "$MAX"); do
  echo "=== Ralph iteration $i/$MAX ==="
  OUTPUT=$(claude -p "$PROMPT" --allowedTools "Edit,Write,Bash,Read,Glob,Grep" 2>&1)
  echo "$OUTPUT"

  if echo "$OUTPUT" | grep -q "<promise>COMPLETE</promise>"; then
    echo ""
    echo "=== All tasks complete after $i iteration(s). ==="
    exit 0
  fi
done

echo "=== Reached max iterations ($MAX) without completion signal. ==="
