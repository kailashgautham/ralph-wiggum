# Ralph Self-Improvement Plan

Ralph is a self-improving loop. Each iteration, Claude reads this file and progress.txt, picks the next uncompleted task, implements it, commits the change, and marks it done.

**Important:** If all tasks are completed, review the codebase for weaknesses and append new improvement tasks to the Tasks section below before proceeding. There should always be work to do.

## Tasks

- [ ] Add error handling and retry logic to ralph.sh (handle Claude CLI failures gracefully)
- [ ] Add logging: write each iteration's summary to a logs/ directory with timestamps
- [ ] Improve README.md with clear usage instructions, examples, and architecture overview
- [ ] Add a CLAUDE.md with project conventions and context for future Claude sessions
- [ ] Support configuring the Claude model via environment variable in ralph.sh
- [ ] Make the prompt in ralph.sh configurable via a prompt.txt file
- [ ] Add input validation to docker-ralph.sh (check Docker is installed, etc.)
- [ ] Add a .env.example documenting available environment variables
- [ ] Add a cleanup command to docker-ralph.sh to remove old containers/images
- [ ] Add git commit after each completed task in ralph.sh
