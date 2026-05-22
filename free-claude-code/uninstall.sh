#!/usr/bin/env bash
# Uninstall free-claude-code: removes service, config, and repo
set -euo pipefail

REPO_DIR="$HOME/repos/free-claude-code"
CONFIG_DIR="$HOME/.config/fish"
SYSTEMD_DIR="/etc/systemd/system"
SERVICE_NAME="free-claude-code"

# Detect VS Code settings file
VSCODE_SETTINGS=""
for base in "$HOME/.config/Code" "$HOME/.config/Code - OSS"; do
    if [ -f "$base/User/settings.json" ]; then
        VSCODE_SETTINGS="$base/User/settings.json"
        break
    fi
done

echo "=== Free Claude Code Uninstall ==="

# 1. Stop and disable systemd service
if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    sudo systemctl stop "$SERVICE_NAME"
    echo "Stopped $SERVICE_NAME"
fi

if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
    sudo systemctl disable "$SERVICE_NAME"
    echo "Disabled $SERVICE_NAME"
fi

if [ -f "$SYSTEMD_DIR/$SERVICE_NAME.service" ]; then
    sudo rm "$SYSTEMD_DIR/$SERVICE_NAME.service"
    sudo systemctl daemon-reload
    echo "Removed systemd unit"
fi

# 2. Remove fish function
if [ -f "$CONFIG_DIR/config.fish" ]; then
    if grep -q 'Claude Code via free-claude-code proxy' "$CONFIG_DIR/config.fish"; then
        sed -i '/^# Claude Code via free-claude-code proxy/,/^end$/d' "$CONFIG_DIR/config.fish"
        sed -i '/^$/N;/^\n$/D' "$CONFIG_DIR/config.fish"
        echo "Removed fish function"
    fi
fi

# 3. Remove VS Code extension settings
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

# 4. Remove shared Claude Code env config
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

# 5. Remove cloned repo
if [ -d "$REPO_DIR" ]; then
    rm -rf "$REPO_DIR"
    echo "Removed $REPO_DIR"
fi

# 6. Uninstall Claude Code CLI
if command -v claude &>/dev/null; then
    npm uninstall -g @anthropic-ai/claude-code
    echo "Uninstalled Claude Code CLI"
fi

echo ""
echo "=== Done ==="
echo "Restart your terminal and reload VS Code to pick up the changes."
