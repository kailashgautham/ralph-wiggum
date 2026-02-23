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
git config --global user.name "Ralph Wiggum"
git config --global user.email "ralph@wiggum.bot"

# Trust the mounted repo directory
git config --global --add safe.directory /app

exec "$@"
