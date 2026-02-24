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
#  12. RALPH_LOG_KEEP=N deletes old .log files beyond the keep limit; non-.log files are preserved
#  13. prompt.txt override is used instead of the default prompt
#  14. RALPH_COMPLETE_HOOK fires with RALPH_EXIT_REASON=stall on stall exit
#  15. RALPH_COMPLETE_HOOK fires with RALPH_EXIT_REASON=max_iterations on max iterations exit
#  16. RALPH_COMPLETE_HOOK fires with RALPH_EXIT_REASON=complete on COMPLETE signal
#  17. docker-ralph.sh status delegates to ralph.sh on the host without invoking Docker
#  18. docker-ralph.sh --dry-run delegates to ralph.sh on the host without invoking Docker
#  19. RALPH_ITER_HOOK is eval'd with RALPH_CURRENT_ITER exported before the Claude invocation
#  20. RALPH_COMPLETE_HOOK fires with RALPH_EXIT_REASON=signal when ralph.sh receives SIGTERM
#  21. Failed planning call preserves progress.txt rather than silently resetting it
#  22. SIGTERM removes claude_output_*.tmp tmpfiles from logs/
#  23. RALPH_CREDIT_WAIT_MAX caps credit-exhaustion retries to a finite count

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
# Test 12: RALPH_LOG_KEEP=N deletes old .log files beyond the keep limit;
#          non-.log files in logs/ are not counted against the limit and not deleted
# ---------------------------------------------------------------------------
echo "Test 12: RALPH_LOG_KEEP=N deletes oldest .log files and preserves non-.log files"
{
  dir=$(setup_repo)
  install_mock_claude_noop "$dir"
  # Pre-populate logs/ with 5 dummy .log files; assign timestamps oldest-to-newest
  # so the rotation order is deterministic regardless of filesystem timing.
  for n in 1 2 3 4 5; do
    touch -t "202001010000.0${n}" "$dir/logs/dummy_${n}.log"
  done
  # Place a non-.log file in logs/ — it must not be counted against the limit or deleted.
  touch "$dir/logs/archive.txt"
  # Run one iteration with RALPH_LOG_KEEP=3; rotation should remove the 2 oldest .log files.
  output=$(cd "$dir" && PATH="$dir/bin:$PATH" RALPH_LOG_KEEP=3 RALPH_NO_GIT=1 bash "$RALPH_SH" 1 2>&1) || true
  # Count remaining .log files in logs/.
  log_count=$(ls "$dir/logs/"*.log 2>/dev/null | wc -l | tr -d ' ')
  oldest_1_gone=0
  oldest_2_gone=0
  archive_kept=0
  [ ! -f "$dir/logs/dummy_1.log" ] && oldest_1_gone=1
  [ ! -f "$dir/logs/dummy_2.log" ] && oldest_2_gone=1
  [ -f "$dir/logs/archive.txt" ] && archive_kept=1
  cleanup_repo "$dir"
  # Expect: 3 kept .log dummies + 1 new run .log = 4 .log files; archive.txt preserved.
  if [ "$log_count" -eq 4 ] && [ "$oldest_1_gone" -eq 1 ] && [ "$oldest_2_gone" -eq 1 ] && [ "$archive_kept" -eq 1 ]; then
    pass "RALPH_LOG_KEEP=3 keeps the 3 newest .log files plus the new run log, removes the 2 oldest, and preserves non-.log files"
  else
    fail "RALPH_LOG_KEEP=3: expected 4 .log files with dummy_1/2 deleted and archive.txt kept; got log_count=$log_count oldest_1_gone=$oldest_1_gone oldest_2_gone=$oldest_2_gone archive_kept=$archive_kept; output=$(echo "$output" | head -5)"
  fi
}

# ---------------------------------------------------------------------------
# Test 13: prompt.txt override is used instead of the default prompt
# ---------------------------------------------------------------------------
echo "Test 13: prompt.txt override is used instead of the default prompt"
{
  dir=$(setup_repo)
  mkdir -p "$dir/bin"
  SENTINEL="SENTINEL_CUSTOM_PROMPT_XYZ_12345"
  echo "$SENTINEL" > "$dir/prompt.txt"
  # Install a mock claude that captures its -p argument to captured_prompt.txt
  cat > "$dir/bin/claude" << 'MOCKEOF'
#!/usr/bin/env bash
prev=""
for arg in "$@"; do
  if [ "$prev" = "-p" ]; then
    printf '%s' "$arg" > "$(pwd)/captured_prompt.txt"
    break
  fi
  prev="$arg"
done
exit 0
MOCKEOF
  chmod +x "$dir/bin/claude"
  output=$(cd "$dir" && PATH="$dir/bin:$PATH" RALPH_NO_GIT=1 bash "$RALPH_SH" 1 2>&1) || true
  captured=""
  [ -f "$dir/captured_prompt.txt" ] && captured=$(cat "$dir/captured_prompt.txt")
  cleanup_repo "$dir"
  if echo "$captured" | grep -qF "$SENTINEL" && ! echo "$captured" | grep -qF "You are working on a software project"; then
    pass "prompt.txt sentinel is passed as the prompt and default prompt text is absent"
  else
    fail "prompt.txt override: expected sentinel in captured prompt without default text; sentinel='$SENTINEL', captured='$(echo "$captured" | head -3)'"
  fi
}

# ---------------------------------------------------------------------------
# Test 14: RALPH_COMPLETE_HOOK fires with RALPH_EXIT_REASON=stall on stall exit
# ---------------------------------------------------------------------------
echo "Test 14: RALPH_COMPLETE_HOOK fires with RALPH_EXIT_REASON=stall on stall exit"
{
  dir=$(setup_repo)
  install_mock_claude_noop "$dir"
  output=$(cd "$dir" && PATH="$dir/bin:$PATH" \
    RALPH_MAX_STALLS=1 \
    RALPH_NO_GIT=1 \
    RALPH_COMPLETE_HOOK='echo "$RALPH_EXIT_REASON" > hook_exit_reason.txt' \
    bash "$RALPH_SH" 10 2>&1) || true
  exit_reason=""
  [ -f "$dir/hook_exit_reason.txt" ] && exit_reason=$(cat "$dir/hook_exit_reason.txt")
  cleanup_repo "$dir"
  if echo "$exit_reason" | grep -q "stall"; then
    pass "RALPH_COMPLETE_HOOK fires with RALPH_EXIT_REASON=stall on stall exit"
  else
    fail "RALPH_COMPLETE_HOOK stall: expected 'stall' in hook file, got '$exit_reason'"
  fi
}

# ---------------------------------------------------------------------------
# Test 15: RALPH_COMPLETE_HOOK fires with RALPH_EXIT_REASON=max_iterations on max iterations exit
# ---------------------------------------------------------------------------
echo "Test 15: RALPH_COMPLETE_HOOK fires with RALPH_EXIT_REASON=max_iterations on max iterations exit"
{
  dir=$(setup_repo)
  install_mock_claude_noop "$dir"
  output=$(cd "$dir" && PATH="$dir/bin:$PATH" \
    RALPH_MAX_STALLS=99 \
    RALPH_NO_GIT=1 \
    RALPH_COMPLETE_HOOK='echo "$RALPH_EXIT_REASON" > hook_exit_reason.txt' \
    bash "$RALPH_SH" 1 2>&1) || true
  exit_reason=""
  [ -f "$dir/hook_exit_reason.txt" ] && exit_reason=$(cat "$dir/hook_exit_reason.txt")
  cleanup_repo "$dir"
  if echo "$exit_reason" | grep -q "max_iterations"; then
    pass "RALPH_COMPLETE_HOOK fires with RALPH_EXIT_REASON=max_iterations on max iterations exit"
  else
    fail "RALPH_COMPLETE_HOOK max_iterations: expected 'max_iterations' in hook file, got '$exit_reason'"
  fi
}

# ---------------------------------------------------------------------------
# Test 16: RALPH_COMPLETE_HOOK fires with RALPH_EXIT_REASON=complete on COMPLETE signal
# ---------------------------------------------------------------------------
echo "Test 16: RALPH_COMPLETE_HOOK fires with RALPH_EXIT_REASON=complete on COMPLETE signal"
{
  dir=$(setup_repo)
  mkdir -p "$dir/bin"
  # Mock claude: outputs COMPLETE on first invocation, no-op on all subsequent calls.
  cat > "$dir/bin/claude" << 'MOCKEOF'
#!/usr/bin/env bash
counter_file="$(pwd)/claude_call_count.txt"
count=$(cat "$counter_file" 2>/dev/null || echo 0)
count=$((count + 1))
echo "$count" > "$counter_file"
if [ "$count" -eq 1 ]; then
  echo "<promise>COMPLETE</promise>"
fi
exit 0
MOCKEOF
  chmod +x "$dir/bin/claude"
  # Use append (>>) so both "complete" and the subsequent "stall" reason are captured.
  output=$(cd "$dir" && PATH="$dir/bin:$PATH" \
    RALPH_MAX_STALLS=1 \
    RALPH_NO_GIT=1 \
    RALPH_COMPLETE_HOOK='echo "$RALPH_EXIT_REASON" >> hook_exit_reason.txt' \
    bash "$RALPH_SH" 5 2>&1) || true
  hook_contents=""
  [ -f "$dir/hook_exit_reason.txt" ] && hook_contents=$(cat "$dir/hook_exit_reason.txt")
  cleanup_repo "$dir"
  if echo "$hook_contents" | grep -q "complete"; then
    pass "RALPH_COMPLETE_HOOK fires with RALPH_EXIT_REASON=complete when COMPLETE signal is detected"
  else
    fail "RALPH_COMPLETE_HOOK complete: expected 'complete' in hook file, got '$hook_contents'"
  fi
}

# ---------------------------------------------------------------------------
# Test 17: docker-ralph.sh status delegates to ralph.sh on the host (no Docker invoked)
# ---------------------------------------------------------------------------
echo "Test 17: docker-ralph.sh status delegates to ralph.sh without invoking Docker"
{
  dir=$(setup_repo)
  echo "[DONE] task alpha" >> "$dir/progress.txt"
  mkdir -p "$dir/bin"
  # Stub docker that always exits non-zero to prove Docker is never invoked
  cat > "$dir/bin/docker" << 'MOCKEOF'
#!/usr/bin/env bash
exit 1
MOCKEOF
  chmod +x "$dir/bin/docker"
  output=$(cd "$dir" && PATH="$dir/bin:$PATH" bash "$DOCKER_RALPH_SH" status 2>&1)
  exit_code=$?
  cleanup_repo "$dir"
  if [ "$exit_code" -eq 0 ] && echo "$output" | grep -q "Ralph Status"; then
    pass "docker-ralph.sh status delegates to ralph.sh on host and exits 0 without invoking Docker"
  else
    fail "docker-ralph.sh status: expected exit 0 and 'Ralph Status', got: $(echo "$output" | head -5) (exit $exit_code)"
  fi
}

# ---------------------------------------------------------------------------
# Test 18: docker-ralph.sh --dry-run delegates to ralph.sh on the host (no Docker invoked)
# ---------------------------------------------------------------------------
echo "Test 18: docker-ralph.sh --dry-run delegates to ralph.sh without invoking Docker"
{
  dir=$(setup_repo)
  mkdir -p "$dir/bin"
  # Stub docker that always exits non-zero to prove Docker is never invoked
  cat > "$dir/bin/docker" << 'MOCKEOF'
#!/usr/bin/env bash
exit 1
MOCKEOF
  chmod +x "$dir/bin/docker"
  output=$(cd "$dir" && PATH="$dir/bin:$PATH" bash "$DOCKER_RALPH_SH" --dry-run 2>&1)
  exit_code=$?
  cleanup_repo "$dir"
  if [ "$exit_code" -eq 0 ] && echo "$output" | grep -q "Next task:"; then
    pass "docker-ralph.sh --dry-run delegates to ralph.sh on host and exits 0 without invoking Docker"
  else
    fail "docker-ralph.sh --dry-run: expected exit 0 and 'Next task:', got: $(echo "$output" | head -5) (exit $exit_code)"
  fi
}

# ---------------------------------------------------------------------------
# Test 19: RALPH_ITER_HOOK is eval'd with RALPH_CURRENT_ITER exported
# ---------------------------------------------------------------------------
echo "Test 19: RALPH_ITER_HOOK writes RALPH_CURRENT_ITER to a file before Claude invocation"
{
  dir=$(setup_repo)
  install_mock_claude_noop "$dir"
  output=$(cd "$dir" && PATH="$dir/bin:$PATH" \
    RALPH_MAX_STALLS=1 \
    RALPH_NO_GIT=1 \
    RALPH_ITER_HOOK='echo "$RALPH_CURRENT_ITER" > iter_hook_out.txt' \
    bash "$RALPH_SH" 1 2>&1) || true
  iter_value=""
  [ -f "$dir/iter_hook_out.txt" ] && iter_value=$(cat "$dir/iter_hook_out.txt")
  cleanup_repo "$dir"
  if echo "$iter_value" | grep -q "^1$"; then
    pass "RALPH_ITER_HOOK fires with RALPH_CURRENT_ITER=1 on the first iteration"
  else
    fail "RALPH_ITER_HOOK: expected '1' in iter_hook_out.txt, got '$iter_value'"
  fi
}

# ---------------------------------------------------------------------------
# Test 20: RALPH_COMPLETE_HOOK fires with RALPH_EXIT_REASON=signal on SIGTERM
# ---------------------------------------------------------------------------
echo "Test 20: RALPH_COMPLETE_HOOK fires with RALPH_EXIT_REASON=signal on SIGTERM"
{
  dir=$(setup_repo)
  mkdir -p "$dir/bin"
  # Mock claude that sleeps briefly so SIGTERM can be delivered while it is running
  cat > "$dir/bin/claude" << 'MOCKEOF'
#!/usr/bin/env bash
sleep 2
exit 0
MOCKEOF
  chmod +x "$dir/bin/claude"
  # Run ralph.sh in background; exec replaces the subshell so $! is ralph.sh's PID
  (
    cd "$dir"
    exec env PATH="$dir/bin:$PATH" \
      RALPH_MAX_STALLS=99 \
      RALPH_NO_GIT=1 \
      RALPH_COMPLETE_HOOK='echo "$RALPH_EXIT_REASON" > hook_exit_reason.txt' \
      bash "$RALPH_SH" 99
  ) >/dev/null 2>&1 &
  ralph_pid=$!
  # Wait for ralph.sh to start and invoke mock claude
  sleep 0.5
  # Send SIGTERM; bash defers the trap until mock claude exits
  kill -TERM "$ralph_pid" 2>/dev/null || true
  # Wait for ralph.sh to fully exit
  wait "$ralph_pid" 2>/dev/null || true
  exit_reason=""
  [ -f "$dir/hook_exit_reason.txt" ] && exit_reason=$(cat "$dir/hook_exit_reason.txt")
  cleanup_repo "$dir"
  if echo "$exit_reason" | grep -q "signal"; then
    pass "RALPH_COMPLETE_HOOK fires with RALPH_EXIT_REASON=signal on SIGTERM"
  else
    fail "RALPH_COMPLETE_HOOK signal: expected 'signal' in hook file, got '$exit_reason'"
  fi
}

# ---------------------------------------------------------------------------
# Test 21: Failed planning call preserves progress.txt (no silent reset)
# ---------------------------------------------------------------------------
echo "Test 21: Failed planning call preserves progress.txt"
{
  dir=$(setup_repo)
  mkdir -p "$dir/bin"
  # Pre-populate progress.txt with a [DONE] entry to verify it is preserved.
  echo "[DONE] task alpha" >> "$dir/progress.txt"
  # Mock claude: outputs COMPLETE on first call (main task), exits 1 on all
  # subsequent calls (planning call inside ralph_handle_complete).
  cat > "$dir/bin/claude" << 'MOCKEOF'
#!/usr/bin/env bash
counter_file="$(pwd)/claude_call_count.txt"
count=$(cat "$counter_file" 2>/dev/null || echo 0)
count=$((count + 1))
echo "$count" > "$counter_file"
if [ "$count" -eq 1 ]; then
  echo "<promise>COMPLETE</promise>"
  exit 0
fi
# Planning and any subsequent calls always fail.
exit 1
MOCKEOF
  chmod +x "$dir/bin/claude"
  # Run ralph.sh with 1 iteration and MAX_RETRIES=1 so the planning call fails
  # fast without retrying (and without sleeping between retry attempts).
  output=$(cd "$dir" && PATH="$dir/bin:$PATH" \
    MAX_RETRIES=1 \
    RALPH_NO_GIT=1 \
    bash "$RALPH_SH" 1 2>&1) || true
  # progress.txt must still contain the [DONE] entry (not be reset to header only).
  progress_contents=""
  [ -f "$dir/progress.txt" ] && progress_contents=$(cat "$dir/progress.txt")
  cleanup_repo "$dir"
  if echo "$progress_contents" | grep -qF "[DONE] task alpha" && \
     echo "$output" | grep -qi "planning call failed"; then
    pass "Failed planning call preserves progress.txt and logs an error"
  else
    fail "Planning failure: expected '[DONE] task alpha' in progress.txt and error in output; progress='$progress_contents', output=$(echo "$output" | head -10)"
  fi
}

# ---------------------------------------------------------------------------
# Test 22: SIGTERM removes claude_output_*.tmp tmpfiles from logs/
# ---------------------------------------------------------------------------
echo "Test 22: SIGTERM removes claude_output_*.tmp tmpfiles from logs/"
{
  dir=$(setup_repo)
  mkdir -p "$dir/bin"
  # Mock claude that sleeps so SIGTERM can be delivered while it is running,
  # giving _ralph_invoke_claude_with_retry time to create the tmpfile first.
  cat > "$dir/bin/claude" << 'MOCKEOF'
#!/usr/bin/env bash
sleep 2
exit 0
MOCKEOF
  chmod +x "$dir/bin/claude"
  # Run ralph.sh in background; exec replaces the subshell so $! is ralph.sh's PID.
  (
    cd "$dir"
    exec env PATH="$dir/bin:$PATH" \
      RALPH_MAX_STALLS=99 \
      RALPH_NO_GIT=1 \
      bash "$RALPH_SH" 99
  ) >/dev/null 2>&1 &
  ralph_pid=$!
  # Wait for ralph.sh to start, create the tmpfile, and invoke mock claude.
  sleep 0.5
  # Send SIGTERM; bash defers the trap until mock claude exits.
  kill -TERM "$ralph_pid" 2>/dev/null || true
  # Wait for ralph.sh to fully exit (after mock claude's 2s sleep).
  wait "$ralph_pid" 2>/dev/null || true
  # No claude_output_*.tmp files should remain after handle_signal cleanup.
  tmp_count=$(ls "$dir/logs/claude_output_"*.tmp 2>/dev/null | wc -l | tr -d ' ')
  cleanup_repo "$dir"
  if [ "$tmp_count" -eq 0 ]; then
    pass "SIGTERM removes claude_output_*.tmp tmpfiles from logs/"
  else
    fail "SIGTERM cleanup: expected 0 claude_output_*.tmp files in logs/, got $tmp_count"
  fi
}

# ---------------------------------------------------------------------------
# Test 23: RALPH_CREDIT_WAIT_MAX caps credit-exhaustion retries
# ---------------------------------------------------------------------------
echo "Test 23: RALPH_CREDIT_WAIT_MAX caps credit-exhaustion retries"
{
  dir=$(setup_repo)
  mkdir -p "$dir/bin"
  # Mock claude: always outputs a credit-exhaustion error and exits 1.
  cat > "$dir/bin/claude" << 'MOCKEOF'
#!/usr/bin/env bash
echo "Error: credit balance too low to perform this action"
exit 1
MOCKEOF
  chmod +x "$dir/bin/claude"
  # Mock sleep: exits instantly so the test does not actually wait 3600 seconds.
  cat > "$dir/bin/sleep" << 'MOCKEOF'
#!/usr/bin/env bash
exit 0
MOCKEOF
  chmod +x "$dir/bin/sleep"
  output=$(cd "$dir" && PATH="$dir/bin:$PATH" \
    RALPH_CREDIT_WAIT_MAX=1 \
    MAX_RETRIES=1 \
    RALPH_NO_GIT=1 \
    bash "$RALPH_SH" 1 2>&1) || true
  cleanup_repo "$dir"
  if echo "$output" | grep -q "Credit-exhaustion wait limit" && \
     echo "$output" | grep -q "RALPH_CREDIT_WAIT_MAX=1"; then
    pass "RALPH_CREDIT_WAIT_MAX=1 caps credit-exhaustion retries and logs the limit error"
  else
    fail "RALPH_CREDIT_WAIT_MAX: expected credit limit error in output; got: $(echo "$output" | head -10)"
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
