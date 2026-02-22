FROM node:20-slim

RUN npm install -g @anthropic-ai/claude-code

RUN mkdir -p /root/.claude

WORKDIR /app

COPY ralph.sh ralph-once.sh entrypoint.sh ./
RUN chmod +x ralph.sh ralph-once.sh entrypoint.sh

ENTRYPOINT ["./entrypoint.sh"]
CMD ["./ralph.sh"]
