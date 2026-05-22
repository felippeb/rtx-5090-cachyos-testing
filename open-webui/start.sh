#!/usr/bin/env bash
# Start Open WebUI and its dependencies
# Usage: ./start-open-webui.sh [llama_port]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LLAMA_PORT="${1:-10500}"

echo "=== Starting Open WebUI stack ==="

# Check llama-server is running
if curl -s -o /dev/null -w "%{http_code}" "http://localhost:${LLAMA_PORT}/v1/models" | grep -q "200"; then
    echo "[OK] llama-server is running on port ${LLAMA_PORT}"
else
    echo "[WARN] llama-server not reachable on port ${LLAMA_PORT}"
    echo "       Start it with: sudo systemctl start llama-server-turbo"
fi

# Start Open WebUI
bash "$SCRIPT_DIR/docker.sh" "$LLAMA_PORT"

echo ""
echo "Open WebUI starting at http://localhost:8080"
echo "Wait ~15 seconds for it to be ready."
