#!/usr/bin/env bash
# docker-ralph.sh — Run the Ralph loop inside a Docker container for sandboxed execution.
# Usage:
#   ./docker-ralph.sh setup            # One-time: export auth from macOS Keychain
#   ./docker-ralph.sh cleanup          # Remove old Ralph containers and images
#   ./docker-ralph.sh [max_iterations]  # Run the ralph loop

set -euo pipefail

IMAGE_NAME="ralph-wiggum"
AUTH_DIR="$(pwd)/.claude-auth"

# --- Input validation ---

# Check Docker is installed
if ! command -v docker &>/dev/null; then
  echo "Error: 'docker' is not installed or not in PATH." >&2
  echo "Install Docker from https://docs.docker.com/get-docker/ and try again." >&2
  exit 1
fi

# Check Docker daemon is running
if ! docker info &>/dev/null; then
  echo "Error: Docker daemon is not running. Start Docker and try again." >&2
  exit 1
fi

# Validate optional max_iterations argument (must be a positive integer if provided)
if [ -n "${1:-}" ] && [ "${1}" != "setup" ] && [ "${1}" != "cleanup" ]; then
  if ! [[ "${1}" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: max_iterations must be a positive integer (got '${1}')." >&2
    echo "Usage: $0 [max_iterations]" >&2
    exit 1
  fi
fi

if [ "${1:-}" = "setup" ]; then
  mkdir -p "$AUTH_DIR"

  if command -v security &>/dev/null; then
    # macOS: extract OAuth token from Keychain
    echo "Exporting Claude credentials from macOS Keychain..."
    CREDS=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null) || {
      echo "Error: No Claude credentials found in Keychain. Run 'claude' and log in first." >&2
      exit 1
    }
    echo "$CREDS" > "$AUTH_DIR/.credentials.json"
    chmod 600 "$AUTH_DIR/.credentials.json"
  else
    # Linux (and other non-macOS): copy credentials directly from ~/.claude/
    echo "Exporting Claude credentials from ~/.claude/..."
    CREDS_SRC="$HOME/.claude/.credentials.json"
    if [ ! -f "$CREDS_SRC" ]; then
      echo "Error: No Claude credentials found at $CREDS_SRC. Run 'claude' and log in first." >&2
      exit 1
    fi
    cp "$CREDS_SRC" "$AUTH_DIR/.credentials.json"
    chmod 600 "$AUTH_DIR/.credentials.json"
  fi

  # Copy .claude.json if it exists (applies on both platforms)
  if [ -f "$HOME/.claude.json" ]; then
    cp "$HOME/.claude.json" "$AUTH_DIR/.claude.json"
    chmod 600 "$AUTH_DIR/.claude.json"
  fi

  echo "Auth exported to .claude-auth/ (gitignored). You can now run: ./docker-ralph.sh"
  exit 0
fi

if [ "${1:-}" = "cleanup" ]; then
  echo "Cleaning up Ralph Docker containers and images..."

  # Remove any stopped containers that used the ralph image
  CONTAINERS=$(docker ps -a --filter "ancestor=${IMAGE_NAME}" -q)
  if [ -n "$CONTAINERS" ]; then
    echo "Removing stopped containers..."
    docker rm -f $CONTAINERS
  else
    echo "No containers to remove."
  fi

  # Remove the ralph image if it exists
  if docker image inspect "$IMAGE_NAME" &>/dev/null; then
    echo "Removing image '${IMAGE_NAME}'..."
    docker rmi "$IMAGE_NAME"
  else
    echo "No image '${IMAGE_NAME}' found."
  fi

  # Remove dangling (untagged) images left over from builds
  DANGLING=$(docker images -f "dangling=true" -q)
  if [ -n "$DANGLING" ]; then
    echo "Removing dangling images..."
    docker rmi $DANGLING
  fi

  # Offer to delete .claude-auth/ credentials directory
  if [ -d "$AUTH_DIR" ]; then
    echo ""
    echo "WARNING: '$AUTH_DIR' contains exported Claude credentials."
    read -r -p "Delete '$AUTH_DIR' and its contents? [y/N] " CONFIRM
    if [[ "${CONFIRM,,}" == "y" || "${CONFIRM,,}" == "yes" ]]; then
      rm -rf "$AUTH_DIR"
      echo "Deleted '$AUTH_DIR'."
    else
      echo "Skipped credential cleanup. '$AUTH_DIR' was left on disk."
    fi
  fi

  echo "Cleanup complete."
  exit 0
fi

# Check auth exists
if [ ! -f "$AUTH_DIR/.credentials.json" ]; then
  echo "Error: No auth found. Run './docker-ralph.sh setup' first." >&2
  exit 1
fi

MAX=${1:-20}

# Build the image
docker build -q -t "$IMAGE_NAME" . > /dev/null

# Collect optional -e flags for environment variables that are set on the host
ENV_ARGS=()
[ -n "${CLAUDE_MODEL:-}" ]      && ENV_ARGS+=(-e "CLAUDE_MODEL=${CLAUDE_MODEL}")
[ -n "${RALPH_TIMEOUT:-}" ]     && ENV_ARGS+=(-e "RALPH_TIMEOUT=${RALPH_TIMEOUT}")
[ -n "${MAX_RETRIES:-}" ]       && ENV_ARGS+=(-e "MAX_RETRIES=${MAX_RETRIES}")
[ -n "${RALPH_MAX_STALLS:-}" ]  && ENV_ARGS+=(-e "RALPH_MAX_STALLS=${RALPH_MAX_STALLS}")

# Determine TTY flags: always keep stdin open (-i), but only allocate a
# pseudo-TTY (-t) when stdout is connected to a terminal.  Passing -t in a
# non-TTY environment (CI, cron, piped invocation) causes docker to error out.
TTY_ARGS=(-i)
[ -t 1 ] && TTY_ARGS+=(-t)

# Run the container, capturing output while still streaming to terminal
TMPOUT=$(mktemp)
set +e
docker run --rm --init "${TTY_ARGS[@]}" \
  -v "$(pwd):/app" \
  -v "$AUTH_DIR:/tmp/claude-auth:ro" \
  -v "$HOME/.ssh/id_ed25519:/root/.ssh/id_ed25519:ro" \
  -v "$HOME/.ssh/known_hosts:/root/.ssh/known_hosts:ro" \
  "${ENV_ARGS[@]+"${ENV_ARGS[@]}"}" \
  "$IMAGE_NAME" ./ralph.sh "$MAX" 2>&1 | tee "$TMPOUT"
DOCKER_EXIT=${PIPESTATUS[0]}
set -e

# Check for auth errors in the output
if grep -qiE "(authentication required|not logged in|invalid credentials|unauthorized|oauth|login required|api key|credentials expired|not authenticated|authentication failed)" "$TMPOUT"; then
  echo "" >&2
  echo "============================================================" >&2
  echo "Auth Error: Claude credentials appear to be invalid or expired." >&2
  echo "" >&2
  echo "To fix this:" >&2
  echo "  1. On your host machine, run:  claude" >&2
  echo "     (This will open the OAuth login flow in your browser)" >&2
  echo "  2. After logging in, re-export your credentials:" >&2
  echo "     ./docker-ralph.sh setup" >&2
  echo "  3. Then run ralph again:" >&2
  echo "     ./docker-ralph.sh" >&2
  echo "============================================================" >&2
  rm -f "$TMPOUT"
  exit 1
fi

rm -f "$TMPOUT"
exit "$DOCKER_EXIT"
