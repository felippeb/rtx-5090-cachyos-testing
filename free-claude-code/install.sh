#!/usr/bin/env bash
# Installs or uninstalls Claude Code CLI + free-claude-code proxy for local llama.cpp backend
# Configures both CLI and VS Code extension.
# Usage: ./free-claude-code-install.sh       # install
#        ./free-claude-code-install.sh --uninstall
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$HOME/repos/free-claude-code"
CONFIG_DIR="$HOME/.config/fish"
SYSTEMD_DIR="/etc/systemd/system"
PROXY_PORT=8082
LLAMA_PORT=10500

# Detect VS Code settings file (works for both VS Code and Code - OSS)
VSCODE_SETTINGS=""
for base in "$HOME/.config/Code" "$HOME/.config/Code - OSS"; do
    if [ -f "$base/User/settings.json" ]; then
        VSCODE_SETTINGS="$base/User/settings.json"
        break
    fi
done

# Uninstall mode
if [ "${1:-}" = "--uninstall" ]; then
    echo "=== Free Claude Code Uninstall ==="

    # Stop and disable systemd service
    if systemctl is-active --quiet free-claude-code 2>/dev/null; then
        sudo systemctl stop free-claude-code
        echo "Stopped free-claude-code service"
    fi
    if systemctl is-enabled --quiet free-claude-code 2>/dev/null; then
        sudo systemctl disable free-claude-code
        echo "Disabled free-claude-code service"
    fi
    if [ -f "$SYSTEMD_DIR/free-claude-code.service" ]; then
        sudo rm "$SYSTEMD_DIR/free-claude-code.service"
        sudo systemctl daemon-reload
        echo "Removed systemd unit"
    fi

    # Remove fish function
    if [ -f "$CONFIG_DIR/config.fish" ]; then
        if grep -q 'Claude Code via free-claude-code proxy' "$CONFIG_DIR/config.fish"; then
            sed -i '/^# Claude Code via free-claude-code proxy/,/^end$/d' "$CONFIG_DIR/config.fish"
            # Clean up any resulting blank lines
            sed -i '/^$/N;/^\n$/D' "$CONFIG_DIR/config.fish"
            echo "Removed fish function"
        fi
    fi

    # Remove VS Code extension settings
    if [ -n "$VSCODE_SETTINGS" ] && [ -f "$VSCODE_SETTINGS" ]; then
        if grep -q 'claudeCode.disableLoginPrompt' "$VSCODE_SETTINGS"; then
            python3 -c "
import json
with open('$VSCODE_SETTINGS', 'r') as f:
    settings = json.load(f)
settings.pop('claudeCode.disableLoginPrompt', None)
settings.pop('claudeCode.environmentVariables', None)
with open('$VSCODE_SETTINGS', 'w') as f:
    json.dump(settings, f, indent=4)
    f.write('\n')
"
            echo "Removed VS Code extension settings"
        fi
    fi

    # Remove shared Claude Code env config
    if [ -f "$HOME/.claude/settings.json" ]; then
        if grep -q 'ANTHROPIC_BASE_URL' "$HOME/.claude/settings.json"; then
            python3 -c "
import json
with open('$HOME/.claude/settings.json', 'r') as f:
    settings = json.load(f)
settings.pop('env', None)
with open('$HOME/.claude/settings.json', 'w') as f:
    json.dump(settings, f, indent=2)
    f.write('\n')
"
            echo "Removed shared Claude Code env config"
        fi
    fi

    # Remove cloned repo (includes .env and .venv)
    if [ -d "$REPO_DIR" ]; then
        rm -rf "$REPO_DIR"
        echo "Removed $REPO_DIR"
    fi

    # Uninstall Claude Code CLI
    if command -v claude &>/dev/null; then
        npm uninstall -g @anthropic-ai/claude-code
        echo "Uninstalled Claude Code CLI"
    fi

    echo ""
    echo "=== Done ==="
    echo "Restart your terminal and reload VS Code to pick up the config changes."
    exit 0
fi

echo "=== Free Claude Code Install ==="

# 0. Check proxy port is free (llama port is expected to be in use)
if ss -tlnp "sport = :$PROXY_PORT" 2>/dev/null | grep -q ":$PROXY_PORT "; then
    echo "ERROR: port $PROXY_PORT is already in use. Kill existing proxy first."
    exit 1
fi

# 1. Install Claude Code CLI
if command -v claude &>/dev/null; then
    echo "Claude Code already installed: $(claude --version)"
else
    echo "Installing Claude Code CLI..."
    npm install -g @anthropic-ai/claude-code
    echo "Installed: $(claude --version)"
fi

# Always run postinstall to ensure native binary is set up
CLAUDE_PKG_PATH="$(npm prefix -g)/lib/node_modules/@anthropic-ai/claude-code"
if [ -f "$CLAUDE_PKG_PATH/install.cjs" ]; then
    echo "Running Claude Code postinstall..."
    node "$CLAUDE_PKG_PATH/install.cjs"
fi

CLAUDE_BIN=$(command -v claude)

# 2. Clone proxy repo
if [ -d "$REPO_DIR" ]; then
    echo "free-claude-code already cloned at $REPO_DIR"
else
    echo "Cloning free-claude-code..."
    git clone https://github.com/Alishahryar1/free-claude-code.git "$REPO_DIR"
fi

# 3. Configure .env
cd "$REPO_DIR"
if [ ! -f .env ]; then
    cp .env.example .env
    echo "Created .env from template"
fi

# Apply llama.cpp configuration (replace entire value, not just prefix)
sed -i 's|LLAMACPP_BASE_URL="http://localhost:8080/v1"|LLAMACPP_BASE_URL="http://localhost:10500/v1"|' .env
sed -i 's|^MODEL_OPUS=.*|MODEL_OPUS="llamacpp/qwen3.6-27b"|' .env
sed -i 's|^MODEL_SONNET=.*|MODEL_SONNET="llamacpp/qwen3.6-27b"|' .env
sed -i 's|^MODEL_HAIKU=.*|MODEL_HAIKU="llamacpp/qwen3.6-27b"|' .env
sed -i 's|^MODEL=.*|MODEL="llamacpp/qwen3.6-27b"|' .env
sed -i 's|^MESSAGING_PLATFORM="discord"|MESSAGING_PLATFORM="none"|' .env
sed -i 's|^PROVIDER_RATE_LIMIT=.*|PROVIDER_RATE_LIMIT=60|' .env
sed -i 's|^PROVIDER_RATE_WINDOW=.*|PROVIDER_RATE_WINDOW=60|' .env

# Validate .env has the expected values
env_ok=true
grep -q 'LLAMACPP_BASE_URL="http://localhost:10500/v1"' .env || { echo "WARN: .env LLAMACPP_BASE_URL mismatch"; env_ok=false; }
grep -q 'MESSAGING_PLATFORM="none"' .env || { echo "WARN: .env MESSAGING_PLATFORM mismatch"; env_ok=false; }
if [ "$env_ok" = false ]; then
    echo "ERROR: .env configuration may be wrong. Check $REPO_DIR/.env manually."
    exit 1
fi
echo "Configured .env for llama.cpp on port $LLAMA_PORT"

# Read proxy API key from .env (used by CLI, fish wrapper, and VS Code)
PROXY_API_KEY=$(grep '^ANTHROPIC_AUTH_TOKEN=' .env | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'")
if [ -z "$PROXY_API_KEY" ]; then
    echo "WARN: ANTHROPIC_AUTH_TOKEN not set in .env — proxy auth disabled"
    PROXY_API_KEY=""
fi

# 4. Install Python dependencies
echo "Installing Python dependencies..."
uv sync
if [ ! -x "$REPO_DIR/.venv/bin/uvicorn" ]; then
    echo "ERROR: uvicorn not found in .venv after uv sync."
    exit 1
fi

# 5. Install and start systemd service (substitute __HOMEDIR__ and __USERNAME__)
if [ -f "$SCRIPT_DIR/services/free-claude-code.service" ]; then
    # Check if service is already installed
    if [ -f "$SYSTEMD_DIR/free-claude-code.service" ]; then
        # Compare with generated version to detect if reinstall is needed
        GENERATED_SERVICE=$(sed -e "s|__HOMEDIR__|${HOME}|g" -e "s|__USERNAME__|${USER:-$(id -un)}|g" \
            "$SCRIPT_DIR/services/free-claude-code.service")
        EXISTING_SERVICE=$(cat "$SYSTEMD_DIR/free-claude-code.service")
        if [ "$GENERATED_SERVICE" = "$EXISTING_SERVICE" ]; then
            echo "Systemd service already installed and up to date"
        else
            echo "Updating systemd service..."
            echo "$GENERATED_SERVICE" | sudo tee "$SYSTEMD_DIR/free-claude-code.service" > /dev/null || {
                echo "ERROR: Failed to update service file. Do you have sudo access?"
                exit 1
            }
            sudo systemctl daemon-reload || { echo "ERROR: daemon-reload failed"; exit 1; }
        fi
    else
        echo "Installing systemd service..."
        sed -e "s|__HOMEDIR__|${HOME}|g" -e "s|__USERNAME__|${USER:-$(id -un)}|g" \
            "$SCRIPT_DIR/services/free-claude-code.service" | \
            sudo tee "$SYSTEMD_DIR/free-claude-code.service" > /dev/null || {
            echo "ERROR: Failed to install service file. Do you have sudo access?"
            exit 1
        }
        sudo systemctl daemon-reload || { echo "ERROR: daemon-reload failed"; exit 1; }
    fi

    # Ensure service is enabled and start if not running
    sudo systemctl enable free-claude-code || { echo "ERROR: Failed to enable service"; exit 1; }

    if systemctl is-active --quiet free-claude-code 2>/dev/null; then
        echo "Service is already running"
    else
        echo "Starting service..."
        sudo systemctl start free-claude-code || { echo "ERROR: Failed to start service"; exit 1; }
    fi

    # Verify service is healthy
    sleep 2
    if systemctl is-active --quiet free-claude-code 2>/dev/null; then
        if ss -tlnp "sport = :$PROXY_PORT" 2>/dev/null | grep -q ":$PROXY_PORT "; then
            echo "Service installed and running on port $PROXY_PORT"
        else
            echo "WARN: Service is active but not listening on port $PROXY_PORT"
            echo "Check logs with: journalctl -u free-claude-code -n 50 --no-pager"
        fi
    else
        echo "ERROR: Service failed to start. Check logs with:"
        echo "  journalctl -u free-claude-code -n 50 --no-pager"
        exit 1
    fi
else
    echo "WARN: Service file not found at $SCRIPT_DIR/services/free-claude-code.service"
fi

# 6. Add fish alias (idempotent – remove old one first)
if [ -f "$CONFIG_DIR/config.fish" ]; then
    # Remove any previous claude function wrapper (including if/end block)
    sed -i '/^# Claude Code via free-claude-code proxy/,/^$/d' "$CONFIG_DIR/config.fish"
fi

cat >> "$CONFIG_DIR/config.fish" << FISH_EOF

# Claude Code via free-claude-code proxy (local llama.cpp)
function claude -w $CLAUDE_BIN
    set -x ANTHROPIC_BASE_URL http://localhost:$PROXY_PORT
    set -x ANTHROPIC_API_KEY $PROXY_API_KEY
    $CLAUDE_BIN \$argv
end
FISH_EOF
echo "Added fish alias to config.fish"

# 7. Configure shared Claude Code settings (~/.claude/settings.json)
echo "Configuring shared Claude Code settings..."
if [ ! -f "$HOME/.claude/settings.json" ]; then
    mkdir -p "$HOME/.claude"
    echo '{}' > "$HOME/.claude/settings.json"
fi

python3 -c "
import json
with open('$HOME/.claude/settings.json', 'r') as f:
    settings = json.load(f)
settings['env'] = {
    'ANTHROPIC_BASE_URL': 'http://localhost:$PROXY_PORT',
    'ANTHROPIC_API_KEY': '$PROXY_API_KEY'
}
with open('$HOME/.claude/settings.json', 'w') as f:
    json.dump(settings, f, indent=2)
    f.write('\n')
"
echo "Updated ~/.claude/settings.json with proxy env vars"

# 8. Configure VS Code extension settings
if [ -n "$VSCODE_SETTINGS" ] && [ -f "$VSCODE_SETTINGS" ]; then
    echo "Configuring VS Code extension..."
    python3 -c "
import json
with open('$VSCODE_SETTINGS', 'r') as f:
    settings = json.load(f)
settings['claudeCode.disableLoginPrompt'] = True
settings['claudeCode.environmentVariables'] = [
    'ANTHROPIC_BASE_URL=http://localhost:$PROXY_PORT',
    'ANTHROPIC_API_KEY=$PROXY_API_KEY'
]
with open('$VSCODE_SETTINGS', 'w') as f:
    json.dump(settings, f, indent=4)
    f.write('\n')
"
    echo "Updated VS Code settings for Claude Code extension"
else
    echo "WARN: VS Code settings not found. Install the extension and configure manually."
    echo "  See FREE_CLAUDE_CODE.md for manual VS Code setup."
fi

echo ""
echo "=== Done ==="
echo "Restart your terminal, then:"
echo "  claude   # run Claude Code CLI"
echo ""
echo "For VS Code extension: reload window (Ctrl+Shift+P → Developer: Reload Window)"
