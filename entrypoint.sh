#!/usr/bin/env bash
set -euo pipefail

# Restore .credentials.json from mounted credentials if available
if [ -f "/tmp/claude-auth/.credentials.json" ]; then
  cp /tmp/claude-auth/.credentials.json /root/.claude/.credentials.json
  chmod 600 /root/.claude/.credentials.json
fi

# Restore .claude.json from mounted config if available
if [ -f "/tmp/claude-auth/.claude.json" ]; then
  cp /tmp/claude-auth/.claude.json /root/.claude.json
  chmod 600 /root/.claude.json
fi

# Configure git identity for commits
git config --global user.name "Kailash Gautham"
git config --global user.email "kailash.gautham@gmail.com"

# Fix SSH key permissions (mounted read-only, but ssh is strict about this)
# Derive the mounted key path from RALPH_SSH_KEY (defaulting to id_ed25519)
SSH_KEY_BASENAME=$(basename "${RALPH_SSH_KEY:-id_ed25519}")
if [ -f "/root/.ssh/${SSH_KEY_BASENAME}" ]; then
  cp "/root/.ssh/${SSH_KEY_BASENAME}" /tmp/ssh_key && chmod 600 /tmp/ssh_key
  export GIT_SSH_COMMAND="ssh -i /tmp/ssh_key -o StrictHostKeyChecking=no"
fi

# Trust the mounted repo directory
git config --global --add safe.directory /app

exec "$@"
