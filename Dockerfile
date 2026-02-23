FROM node:20.19-slim

RUN apt-get update && apt-get install -y git curl openssh-client && rm -rf /var/lib/apt/lists/*

# Install GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y gh && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code@2.1.50

RUN mkdir -p /root/.claude

WORKDIR /app

COPY ralph.sh ralph-once.sh entrypoint.sh ./
RUN chmod +x ralph.sh ralph-once.sh entrypoint.sh

ENTRYPOINT ["./entrypoint.sh"]
CMD ["./ralph.sh"]
