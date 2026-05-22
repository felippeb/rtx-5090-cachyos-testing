#!/usr/bin/env bash
# Stop DuckDuckGo MCP Server container
# Usage: ./stop.sh [--all]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Stopping DuckDuckGo MCP Server ==="

# Stop and remove the container
if docker ps --format '{{.Names}}' | grep -q '^duckduckgo-mcp$'; then
    echo "Stopping duckduckgo-mcp container..."
    docker compose -f "$SCRIPT_DIR/docker-compose.yml" down
    echo "[OK] duckduckgo-mcp stopped and removed"
else
    echo "[INFO] duckduckgo-mcp container not running"
fi

# Optionally remove the image too
if [[ "${1:-}" == "--all" ]]; then
    docker compose -f "$SCRIPT_DIR/docker-compose.yml" down --rmi local --volumes
    echo "[OK] Image and volumes removed"
fi

echo ""
echo "Done."
