#!/usr/bin/env bash
# Stop the free-claude-code proxy service
set -euo pipefail

SERVICE_NAME="free-claude-code"

if ! systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    echo "Service $SERVICE_NAME is not running."
    exit 0
fi

echo "Stopping $SERVICE_NAME..."
sudo systemctl stop "$SERVICE_NAME"
echo "Service stopped."
