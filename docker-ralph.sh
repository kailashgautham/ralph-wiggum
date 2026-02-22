#!/usr/bin/env bash
# docker-ralph.sh — Run the Ralph loop inside a Docker container for sandboxed execution.
# Usage: ./docker-ralph.sh [max_iterations]
#
# Auth: Set ANTHROPIC_API_KEY env var, OR rely on ~/.claude host config being mounted.

set -euo pipefail

# Load .env if present
if [ -f .env ]; then
  set -a; source .env; set +a
fi

IMAGE_NAME="ralph-wiggum"
MAX=${1:-20}

# Build the image if needed
docker build -t "$IMAGE_NAME" .

AUTH_ARGS=()
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  AUTH_ARGS+=(-e "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY")
elif [ -d "$HOME/.claude" ]; then
  AUTH_ARGS+=(-v "$HOME/.claude:/root/.claude:ro")
else
  echo "Error: Set ANTHROPIC_API_KEY or ensure ~/.claude exists for auth." >&2
  exit 1
fi

# Run the ralph loop in a container:
#   - Mount current directory to /app so Claude edits your real project files
#   - Pass auth credentials
#   - Use --rm to clean up the container after exit
docker run --rm \
  -v "$(pwd):/app" \
  "${AUTH_ARGS[@]}" \
  "$IMAGE_NAME" "$MAX"
