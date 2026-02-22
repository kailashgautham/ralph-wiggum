FROM node:20-slim

# Install Claude Code CLI
RUN npm install -g @anthropic-ai/claude-code

# Working directory where the project will be mounted
WORKDIR /app

# Copy the ralph scripts
COPY ralph.sh ralph-once.sh ./
RUN chmod +x ralph.sh ralph-once.sh

ENTRYPOINT ["./ralph.sh"]
