# Browser Harness Setup

Connects an LLM directly to your real Brave browser via CDP (Chrome DevTools Protocol).

## Quick Start

```bash
# 1. Launch Brave with remote debugging (localhost only by default)
brave --remote-debugging-port=9222

# 2. Test connection
BU_CDP_URL=http://127.0.0.1:9222 browser-harness -c 'print(page_info())'
```

## Installed

- Tool: `uv tool install -e ~/repos/browser-harness` (global)
- Repo: `~/repos/browser-harness` (symlinked from rtx-5090-cachyos-testing/)
- Version: 0.1.0 (git)

## Notes

- `--remote-debugging-port=9222` binds to 127.0.0.1 only — not accessible from outside
- Your old Brave instance (PID 3502) does NOT have remote debugging enabled
- Need a fresh launch with the flag each session
- Daemon communicates via Unix socket at `/tmp/bu-default.sock`

## Troubleshooting

```bash
# Check connection
BU_CDP_URL=http://127.0.0.1:9222 browser-harness --doctor

# Stale daemon? Clean up and retry
rm -f /tmp/bu-default.* 
BU_CDP_URL=http://127.0.0.1:9222 browser-harness -c 'print(page_info())'
```

## Why This vs Chrome DevTools MCP

| | browser-harness | chrome-devtools-mcp |
|---|---|---|
| Browser | Your real Brave/Chrome | Spawns isolated Chromium |
| Your profile | Yes (logins, cookies, extensions) | No |
| Use case | Tasks needing auth (Gmail, GitHub) | Screenshots, navigation, form filling |
