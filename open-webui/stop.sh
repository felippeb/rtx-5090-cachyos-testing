#!/usr/bin/env bash
# Stop Open WebUI and optionally llama-server
# Usage: ./stop-open-webui.sh [--all]

set -e

echo "=== Stopping Open WebUI stack ==="

# Stop Open WebUI container
if docker ps --format '{{.Names}}' | grep -q '^open-webui$'; then
    echo "Stopping open-webui container..."
    docker stop open-webui
    docker rm open-webui
    echo "[OK] open-webui stopped and removed"
else
    echo "[INFO] open-webui container not running"
fi

# Optionally stop llama-server too
if [[ "${1:-}" == "--all" ]]; then
    for svc in llama-server-turbo llama-server; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            echo "Stopping $svc..."
            sudo systemctl stop "$svc"
            echo "[OK] $svc stopped"
        fi
    done
fi

echo ""
echo "Done."
