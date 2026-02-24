#!/usr/bin/env bash
# tests/run_tests.sh — Test harness for ralph.sh core behaviours.
# Uses temporary directories and mock git repos; does not require a real Claude CLI.
#
# Tested behaviours:
#   1. --dry-run prints the correct next task and exits 0
#   2. status counts completed vs remaining correctly
#   3. lockfile prevents concurrent invocations
#   4. stall detection exits after RALPH_MAX_STALLS consecutive no-progress iterations
#   5. full-line task-completion matching does not produce false positives
#   6. ralph-once.sh exits non-zero with an error when claude is absent
#   7. docker-ralph.sh prints error and exits 1 for non-integer max_iterations
#   8. RALPH_LOG_KEEP=0 passes validation and exits 0 (log-rotation skipped)
#   9. RALPH_LOG_KEEP=abc exits 1 with "must be a non-negative integer"
#  10. ralph-once.sh --dry-run prints the correct next task and exits 0
#  11. ralph-once.sh status counts completed vs remaining correctly
#  12. RALPH_LOG_KEEP=N deletes old log files beyond the keep limit

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RALPH_SH="$(dirname "$TESTS_DIR")/ralph.sh"
RALPH_ONCE_SH="$(dirname "$TESTS_DIR")/ralph-once.sh"
DOCKER_RALPH_SH="$(dirname "$TESTS_DIR")/docker-ralph.sh"

PASS=0
FAIL=0

pass() {
  echo "  PASS: $1"
  PASS=$((PASS + 1))
}

fail() {
  echo "  FAIL: $1"
  FAIL=$((FAIL + 1))
}

# Set up a minimal git repo with PRD.md and progress.txt in a temp dir.
# Prints the path of the created directory.
setup_repo() {
  local dir
  dir=$(mktemp -d)
  git -C "$dir" init -q
  git -C "$dir" config user.email "test@ralph.test"
  git -C "$dir" config user.name "Ralph Test"
  mkdir -p "$dir/logs"
  cat > "$dir/PRD.md" << 'PRDEOF'
# Test PRD

## Tasks
- [ ] task alpha
- [ ] task alpha extended
- [ ] task beta
PRDEOF
  printf "# Progress Tracker\n# Format: [DONE] Task description\n" > "$dir/progress.txt"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "init"
  echo "$dir"
}

cleanup_repo() {
  rm -rf "$1"
}

# Install a no-op mock claude into $dir/bin (exits 0, makes no file changes).
install_mock_claude_noop() {
  local dir="$1"
  mkdir -p "$dir/bin"
  cat > "$dir/bin/claude" << 'MOCKEOF'
#!/usr/bin/env bash
echo "mock-claude: no-op"
exit 0
MOCKEOF
  chmod +x "$dir/bin/claude"
}

echo "Running ralph.sh tests..."
echo ""

# ---------------------------------------------------------------------------
# Test 1: --dry-run prints the correct next task and exits 0
# ---------------------------------------------------------------------------
echo "Test 1: --dry-run prints the correct next task"
{
  dir=$(setup_repo)
  output=$(cd "$dir" && bash "$RALPH_SH" --dry-run 2>&1)
  exit_code=$?
  cleanup_repo "$dir"
  if [ "$exit_code" -eq 0 ] && echo "$output" | grep -qE "^Next task: task alpha$"; then
    pass "--dry-run prints the correct next task and exits 0"
  else
    fail "--dry-run: expected 'Next task: task alpha', got: $(echo "$output" | head -5) (exit $exit_code)"
  fi
}

# ---------------------------------------------------------------------------
# Test 2: status counts completed vs remaining correctly
# ---------------------------------------------------------------------------
echo "Test 2: status counts completed vs remaining"
{
  dir=$(setup_repo)
  echo "[DONE] task alpha" >> "$dir/progress.txt"
  output=$(cd "$dir" && bash "$RALPH_SH" status 2>&1)
  exit_code=$?
  cleanup_repo "$dir"
  if [ "$exit_code" -eq 0 ] && \
     echo "$output" | grep -q "1 completed" && \
     echo "$output" | grep -q "2 remaining"; then
    pass "status counts 1 completed and 2 remaining correctly"
  else
    fail "status: expected '1 completed' and '2 remaining', got: $(echo "$output" | head -5) (exit $exit_code)"
  fi
}

# ---------------------------------------------------------------------------
# Test 3: lockfile prevents concurrent invocations
# ---------------------------------------------------------------------------
echo "Test 3: lockfile prevents concurrent invocations"
{
  dir=$(setup_repo)
  install_mock_claude_noop "$dir"
  # Hold the lockfile from a background subshell before ralph.sh can acquire it
  (
    exec 9>"$dir/.ralph.lock"
    flock -x 9
    sleep 10
  ) &
  bg_pid=$!
  sleep 0.3  # allow background process time to acquire the lock
  output=$(cd "$dir" && PATH="$dir/bin:$PATH" bash "$RALPH_SH" 1 2>&1) || true
  kill "$bg_pid" 2>/dev/null || true
  wait "$bg_pid" 2>/dev/null || true
  cleanup_repo "$dir"
  if echo "$output" | grep -q "already running"; then
    pass "lockfile prevents concurrent invocations"
  else
    fail "lockfile: expected 'already running', got: $(echo "$output" | head -5)"
  fi
}

# ---------------------------------------------------------------------------
# Test 4: stall detection exits after RALPH_MAX_STALLS consecutive no-progress iterations
# ---------------------------------------------------------------------------
echo "Test 4: stall detection exits after RALPH_MAX_STALLS no-progress iterations"
{
  dir=$(setup_repo)
  install_mock_claude_noop "$dir"
  output=$(cd "$dir" && PATH="$dir/bin:$PATH" RALPH_MAX_STALLS=2 bash "$RALPH_SH" 10 2>&1) || true
  cleanup_repo "$dir"
  if echo "$output" | grep -q "stalled"; then
    pass "stall detection increments and exits after RALPH_MAX_STALLS consecutive no-progress iterations"
  else
    fail "stall detection: expected stall exit message, got: $(echo "$output" | head -10)"
  fi
}

# ---------------------------------------------------------------------------
# Test 5: full-line matching does not produce false positives
#   "task alpha extended" is done; "task alpha" (a leading substring) must NOT
#   be treated as done by a substring match.
# ---------------------------------------------------------------------------
echo "Test 5: full-line matching does not produce false positives"
{
  dir=$(setup_repo)
  # Mark only the longer task as done
  echo "[DONE] task alpha extended" >> "$dir/progress.txt"
  # --dry-run should identify "task alpha" as the next pending task (not falsely skip it)
  dry_output=$(cd "$dir" && bash "$RALPH_SH" --dry-run 2>&1)
  dry_exit=$?
  # status should list "task alpha" in Remaining and "task alpha extended" in Completed
  status_output=$(cd "$dir" && bash "$RALPH_SH" status 2>&1)
  cleanup_repo "$dir"
  if [ "$dry_exit" -eq 0 ] && \
     echo "$dry_output" | grep -qE "^Next task: task alpha$" && \
     echo "$status_output" | grep -qF "[x] task alpha extended" && \
     echo "$status_output" | grep -qF "[ ] task alpha"; then
    pass "full-line matching does not produce false positives for substring task descriptions"
  else
    fail "full-line matching: dry_output='$dry_output' status_output='$(echo "$status_output" | head -10)'"
  fi
}

# ---------------------------------------------------------------------------
# Test 6: ralph-once.sh exits non-zero with an error when claude is absent
# ---------------------------------------------------------------------------
echo "Test 6: ralph-once.sh exits non-zero when claude is absent from PATH"
{
  dir=$(setup_repo)
  # Use a minimal PATH containing only core system bins; claude is never at /usr/bin or /bin
  output=$(cd "$dir" && PATH="/usr/bin:/bin" bash "$RALPH_ONCE_SH" 2>&1)
  exit_code=$?
  cleanup_repo "$dir"
  if [ "$exit_code" -ne 0 ] && echo "$output" | grep -q "Error: 'claude' not found"; then
    pass "ralph-once.sh exits non-zero with 'claude not found' error when claude is absent from PATH"
  else
    fail "ralph-once.sh: expected non-zero exit and 'claude not found' error, got: $(echo "$output" | head -5) (exit $exit_code)"
  fi
}

# ---------------------------------------------------------------------------
# Test 7: docker-ralph.sh prints error and exits 1 for non-integer max_iterations
# ---------------------------------------------------------------------------
echo "Test 7: docker-ralph.sh exits 1 for non-integer max_iterations"
{
  dir=$(mktemp -d)
  mkdir -p "$dir/bin"
  # Provide a mock docker that always exits 0 (satisfies both the install and daemon checks)
  cat > "$dir/bin/docker" << 'MOCKEOF'
#!/usr/bin/env bash
exit 0
MOCKEOF
  chmod +x "$dir/bin/docker"
  output=$(cd "$dir" && PATH="$dir/bin:$PATH" bash "$DOCKER_RALPH_SH" "abc" 2>&1)
  exit_code=$?
  rm -rf "$dir"
  if [ "$exit_code" -eq 1 ] && echo "$output" | grep -q "max_iterations must be a positive integer"; then
    pass "docker-ralph.sh prints clear error and exits 1 for non-integer max_iterations"
  else
    fail "docker-ralph.sh: expected exit 1 and 'max_iterations must be a positive integer', got: $(echo "$output" | head -5) (exit $exit_code)"
  fi
}

# ---------------------------------------------------------------------------
# Test 8: RALPH_LOG_KEEP=0 passes validation and exits 0 (log-rotation skipped)
# ---------------------------------------------------------------------------
echo "Test 8: RALPH_LOG_KEEP=0 exits 0 without a validation error"
{
  dir=$(setup_repo)
  install_mock_claude_noop "$dir"
  output=$(cd "$dir" && PATH="$dir/bin:$PATH" RALPH_LOG_KEEP=0 bash "$RALPH_SH" 1 2>&1) || true
  exit_code=$?
  cleanup_repo "$dir"
  if [ "$exit_code" -eq 0 ] && ! echo "$output" | grep -q "must be a non-negative integer"; then
    pass "RALPH_LOG_KEEP=0 passes validation and exits 0"
  else
    fail "RALPH_LOG_KEEP=0: expected exit 0 and no validation error, got: $(echo "$output" | head -5) (exit $exit_code)"
  fi
}

# ---------------------------------------------------------------------------
# Test 9: RALPH_LOG_KEEP=abc exits 1 with "must be a non-negative integer"
# ---------------------------------------------------------------------------
echo "Test 9: RALPH_LOG_KEEP=abc exits 1 with validation error"
{
  dir=$(setup_repo)
  install_mock_claude_noop "$dir"
  output=$(cd "$dir" && PATH="$dir/bin:$PATH" RALPH_LOG_KEEP=abc bash "$RALPH_SH" 1 2>&1)
  exit_code=$?
  cleanup_repo "$dir"
  if [ "$exit_code" -eq 1 ] && echo "$output" | grep -q "must be a non-negative integer"; then
    pass "RALPH_LOG_KEEP=abc exits 1 with 'must be a non-negative integer'"
  else
    fail "RALPH_LOG_KEEP=abc: expected exit 1 and 'must be a non-negative integer', got: $(echo "$output" | head -5) (exit $exit_code)"
  fi
}

# ---------------------------------------------------------------------------
# Test 10: ralph-once.sh --dry-run prints the correct next task and exits 0
# ---------------------------------------------------------------------------
echo "Test 10: ralph-once.sh --dry-run prints the correct next task"
{
  dir=$(setup_repo)
  output=$(cd "$dir" && bash "$RALPH_ONCE_SH" --dry-run 2>&1)
  exit_code=$?
  cleanup_repo "$dir"
  if [ "$exit_code" -eq 0 ] && echo "$output" | grep -qE "^Next task: task alpha$"; then
    pass "ralph-once.sh --dry-run prints the correct next task and exits 0"
  else
    fail "ralph-once.sh --dry-run: expected 'Next task: task alpha', got: $(echo "$output" | head -5) (exit $exit_code)"
  fi
}

# ---------------------------------------------------------------------------
# Test 11: ralph-once.sh status counts completed vs remaining correctly
# ---------------------------------------------------------------------------
echo "Test 11: ralph-once.sh status counts completed vs remaining"
{
  dir=$(setup_repo)
  echo "[DONE] task alpha" >> "$dir/progress.txt"
  output=$(cd "$dir" && bash "$RALPH_ONCE_SH" status 2>&1)
  exit_code=$?
  cleanup_repo "$dir"
  if [ "$exit_code" -eq 0 ] && \
     echo "$output" | grep -q "1 completed" && \
     echo "$output" | grep -q "2 remaining"; then
    pass "ralph-once.sh status counts 1 completed and 2 remaining correctly"
  else
    fail "ralph-once.sh status: expected '1 completed' and '2 remaining', got: $(echo "$output" | head -5) (exit $exit_code)"
  fi
}

# ---------------------------------------------------------------------------
# Test 12: RALPH_LOG_KEEP=N deletes old log files beyond the keep limit
# ---------------------------------------------------------------------------
echo "Test 12: RALPH_LOG_KEEP=N deletes oldest log files beyond the keep limit"
{
  dir=$(setup_repo)
  install_mock_claude_noop "$dir"
  # Pre-populate logs/ with 5 dummy files; assign timestamps oldest-to-newest
  # so the rotation order is deterministic regardless of filesystem timing.
  for n in 1 2 3 4 5; do
    touch -t "202001010000.0${n}" "$dir/logs/dummy_${n}.log"
  done
  # Run one iteration with RALPH_LOG_KEEP=3; rotation should remove the 2 oldest.
  output=$(cd "$dir" && PATH="$dir/bin:$PATH" RALPH_LOG_KEEP=3 RALPH_NO_GIT=1 bash "$RALPH_SH" 1 2>&1) || true
  # Count remaining files in logs/ (non-hidden only).
  log_count=$(ls "$dir/logs/" | wc -l | tr -d ' ')
  oldest_1_gone=0
  oldest_2_gone=0
  [ ! -f "$dir/logs/dummy_1.log" ] && oldest_1_gone=1
  [ ! -f "$dir/logs/dummy_2.log" ] && oldest_2_gone=1
  cleanup_repo "$dir"
  # Expect: 3 kept dummies + 1 new run log = 4 total; dummy_1 and dummy_2 deleted.
  if [ "$log_count" -eq 4 ] && [ "$oldest_1_gone" -eq 1 ] && [ "$oldest_2_gone" -eq 1 ]; then
    pass "RALPH_LOG_KEEP=3 keeps the 3 newest log files plus the new run log and removes the 2 oldest"
  else
    fail "RALPH_LOG_KEEP=3: expected 4 files with dummy_1 and dummy_2 deleted, got $log_count files (dummy_1_gone=$oldest_1_gone, dummy_2_gone=$oldest_2_gone); output=$(echo "$output" | head -5)"
  fi
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed."
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
