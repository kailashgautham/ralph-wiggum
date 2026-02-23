#!/usr/bin/env node
// ralph-github.js — GitHub API helper for the Ralph PR workflow.
// Usage:
//   RALPH_GITHUB_REPO=owner/repo GH_TOKEN=... node ralph-github.js create-pr <branch> <base> <title>
//   RALPH_GITHUB_REPO=owner/repo GH_TOKEN=... node ralph-github.js merge-pr <pr-number>

const https = require('https');

const TOKEN = process.env.GH_TOKEN || process.env.GITHUB_TOKEN;
const REPO  = process.env.RALPH_GITHUB_REPO;

function apiRequest(method, path, body) {
  return new Promise((resolve, reject) => {
    const payload = body ? JSON.stringify(body) : null;
    const options = {
      hostname: 'api.github.com',
      path: `/repos/${REPO}${path}`,
      method,
      headers: {
        'User-Agent': 'ralph-wiggum/1.0',
        'Authorization': `token ${TOKEN}`,
        'Content-Type': 'application/json',
        'Accept': 'application/vnd.github.v3+json',
      },
    };
    if (payload) {
      options.headers['Content-Length'] = Buffer.byteLength(payload);
    }
    const req = https.request(options, (res) => {
      let data = '';
      res.on('data', (chunk) => { data += chunk; });
      res.on('end', () => {
        try {
          resolve({ status: res.statusCode, body: JSON.parse(data) });
        } catch {
          resolve({ status: res.statusCode, body: data });
        }
      });
    });
    req.on('error', reject);
    if (payload) req.write(payload);
    req.end();
  });
}

async function main() {
  const [, , cmd, ...args] = process.argv;

  if (!TOKEN) {
    console.error('Error: GH_TOKEN or GITHUB_TOKEN environment variable is required.');
    process.exit(1);
  }
  if (!REPO) {
    console.error('Error: RALPH_GITHUB_REPO environment variable is required (format: owner/repo).');
    process.exit(1);
  }

  if (cmd === 'create-pr') {
    const [branch, base, ...titleParts] = args;
    const title = titleParts.join(' ');
    const res = await apiRequest('POST', '/pulls', {
      title,
      head: branch,
      base,
      body: 'Automated task completion by the Ralph self-improvement loop.',
    });
    if (res.status === 201) {
      process.stdout.write(String(res.body.number) + '\n');
    } else {
      const msg = (res.body && res.body.message) ? res.body.message : JSON.stringify(res.body);
      console.error(`Error creating PR (HTTP ${res.status}): ${msg}`);
      process.exit(1);
    }

  } else if (cmd === 'merge-pr') {
    const [prNumber] = args;
    const res = await apiRequest('PUT', `/pulls/${prNumber}/merge`, {
      merge_method: 'merge',
    });
    if (res.status === 200) {
      console.log(`PR #${prNumber} merged successfully.`);
    } else {
      const msg = (res.body && res.body.message) ? res.body.message : JSON.stringify(res.body);
      console.error(`Error merging PR #${prNumber} (HTTP ${res.status}): ${msg}`);
      process.exit(1);
    }

  } else {
    console.error(`Unknown command: ${cmd}. Use 'create-pr' or 'merge-pr'.`);
    process.exit(1);
  }
}

main().catch((err) => {
  console.error('Unexpected error:', err.message || err);
  process.exit(1);
});
