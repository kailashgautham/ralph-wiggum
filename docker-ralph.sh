#!/usr/bin/env bash
# docker-ralph.sh — Run the Ralph loop inside a Docker container for sandboxed execution.
# Usage:
#   ./docker-ralph.sh setup            # One-time: export auth from macOS Keychain
#   ./docker-ralph.sh [max_iterations]  # Run the ralph loop

set -euo pipefail

IMAGE_NAME="ralph-wiggum"
AUTH_DIR="$(pwd)/.claude-auth"

if [ "${1:-}" = "setup" ]; then
  echo "Exporting Claude credentials from macOS Keychain..."
  mkdir -p "$AUTH_DIR"

  # Extract OAuth token from macOS Keychain
  CREDS=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null) || {
    echo "Error: No Claude credentials found in Keychain. Run 'claude' and log in first." >&2
    exit 1
  }
  echo "$CREDS" > "$AUTH_DIR/.credentials.json"
  chmod 600 "$AUTH_DIR/.credentials.json"

  # Copy .claude.json if it exists
  if [ -f "$HOME/.claude.json" ]; then
    cp "$HOME/.claude.json" "$AUTH_DIR/.claude.json"
    chmod 600 "$AUTH_DIR/.claude.json"
  fi

  echo "Auth exported to .claude-auth/ (gitignored). You can now run: ./docker-ralph.sh"
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

docker run --rm \
  -v "$(pwd):/app" \
  -v "$AUTH_DIR:/tmp/claude-auth:ro" \
  "$IMAGE_NAME" ./ralph.sh "$MAX"
