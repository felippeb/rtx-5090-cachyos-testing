# Free Claude Code Setup

Use Claude Code (CLI and VS Code extension) with your local llama.cpp backend — no Anthropic subscription required.

## What It Does

`free-claude-code` is a transparent proxy that intercepts Claude Code's Anthropic API calls and routes them to your local LLM. Claude Code thinks it's talking to Anthropic; the proxy forwards requests to llama.cpp instead.

```
Claude Code CLI / VS Code → free-claude-code proxy (:8082) → llama.cpp (:10500)
```


## Quick Install

```fish
bash ~/repos/cachy-os-opencode-rtx-5090/free-claude-code-install.sh
```

Installs Claude Code CLI, clones the proxy, configures for llama.cpp, creates systemd service, adds fish alias, and configures the VS Code extension.

## Architecture

Both the CLI and VS Code extension share the same proxy. Configuration lives in three places:

| Config | Where | Used By |
| --- | --- | --- |
| `~/.claude/settings.json` | `env` block | CLI + VS Code extension (shared) |
| `~/.config/fish/config.fish` | `claude` function wrapper | CLI only (shell-level) |
| VS Code `settings.json` | `claudeCode.*` settings | VS Code extension only |

## Manual Steps

### 1. Install Claude Code CLI

```fish
npm install -g @anthropic-ai/claude-code
```

### 2. Clone and configure proxy

```fish
git clone https://github.com/Alishahryar1/free-claude-code.git ~/repos/free-claude-code
cd ~/repos/free-claude-code
cp .env.example .env
```

Edit `.env`:
```bash
LLAMACPP_BASE_URL="http://localhost:10500/v1"
MODEL_OPUS="llamacpp/qwen3.6-27b"
MODEL_SONNET="llamacpp/qwen3.6-27b"
MODEL_HAIKU="llamacpp/qwen3.6-27b"
MODEL="llamacpp/qwen3.6-27b"
MESSAGING_PLATFORM="none"
PROVIDER_RATE_LIMIT=60
PROVIDER_RATE_WINDOW=60
```

### 3. Install Python dependencies

```fish
uv sync
```

### 4. Run the proxy

```fish
uv run uvicorn server:app --host 0.0.0.0 --port 8082
```

### 5. Configure Claude Code

#### Shared config (CLI + VS Code)

In `~/.claude/settings.json`:
```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "http://localhost:8082",
    "ANTHROPIC_API_KEY": "sk-ant-proxy-local"
  }
}
```

#### CLI — fish alias

In `~/.config/fish/config.fish`:
```fish
function claude -w (command -v claude)
    set -x ANTHROPIC_BASE_URL http://localhost:8082
    set -x ANTHROPIC_API_KEY sk-ant-proxy-local
    (command -v claude) $argv
end
```

#### VS Code extension

In VS Code settings (`Ctrl+,` → Extensions → Claude Code, or edit `~/.config/Code - OSS/User/settings.json`):
```json
{
  "claudeCode.disableLoginPrompt": true,
  "claudeCode.environmentVariables": [
    "ANTHROPIC_BASE_URL=http://localhost:8082",
    "ANTHROPIC_API_KEY=sk-ant-proxy-local"
  ]
}
```

After changing settings, reload VS Code (Command Palette → "Developer: Reload Window").

### 6. Run

```fish
claude   # CLI
```

Or open the Claude Code panel in VS Code (Spark icon in editor toolbar or Activity Bar).

## Features

- **Zero cost** — routes to your local llama.cpp, no API calls to Anthropic
- **CLI and VS Code** — works in both Claude Code CLI and the VS Code extension
- **Drop-in replacement** — Claude Code works unchanged, just point at the proxy
- **Per-model mapping** — route Opus/Sonnet/Haiku to different models
- **Request optimization** — 5 categories of trivial requests intercepted locally
- **Smart rate limiting** — rolling-window throttle + exponential backoff
- **Thinking token support** — parses reasoning tags into Claude thinking blocks

## Limitations

- Still requires Claude Code binary (CLI via npm, extension from VS Code marketplace)
- VS Code extension requires `disableLoginPrompt` to skip OAuth screen
- Tool calling quality depends on your local model's capabilities
- No access to Anthropic's proprietary features (web search, etc.)

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| CLI login screen won't dismiss | Ensure `ANTHROPIC_API_KEY` is set in your fish alias |
| VS Code shows login screen | Ensure `claudeCode.disableLoginPrompt` is `true` |
| VS Code "Not logged in · Please run /login" | Check `claudeCode.environmentVariables` has both env vars |
| Proxy won't start | Check `uv sync` completed, verify Python 3.14 |
| `claude` infinite loop | Use `function` wrapper in fish, not `alias` |
| Claude Code hangs on first request | Verify llama.cpp is running on port 10500 |
| Proxy 401 errors | Set matching `ANTHROPIC_AUTH_TOKEN` in `.env` and alias |
| VS Code extension not found | Install from [marketplace](https://marketplace.visualstudio.com/items?itemName=anthropic.claude-code) or run "Developer: Reload Window" |

## Links

| Resource | URL |
| --- | --- |
| free-claude-code | https://github.com/Alishahryar1/free-claude-code |
| Claude Code | https://github.com/anthropics/claude-code |
| llama.cpp | https://github.com/ggml-org/llama.cpp |
