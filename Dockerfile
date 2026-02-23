FROM node:20.19-slim

RUN apt-get update && apt-get install -y git && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code@2.1.50

RUN mkdir -p /root/.claude

WORKDIR /app

COPY ralph.sh ralph-once.sh entrypoint.sh ./
RUN chmod +x ralph.sh ralph-once.sh entrypoint.sh

ENTRYPOINT ["./entrypoint.sh"]
CMD ["./ralph.sh"]
