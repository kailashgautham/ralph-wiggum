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
if [ -f /root/.ssh/id_ed25519 ]; then
  cp /root/.ssh/id_ed25519 /tmp/ssh_key && chmod 600 /tmp/ssh_key
  export GIT_SSH_COMMAND="ssh -i /tmp/ssh_key -o StrictHostKeyChecking=no"
fi

# Trust the mounted repo directory
git config --global --add safe.directory /app

exec "$@"
