#!/usr/bin/env bash
# Start DuckDuckGo MCP Server container
# Provides web search via streamable-HTTP transport on port 8000
#
# Usage: ./start.sh [--rebuild]
#   --rebuild: rebuild the Docker image before starting

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REBUILD="${1:-}"

echo "=== Starting DuckDuckGo MCP Server ==="

if [[ "$REBUILD" == "--rebuild" ]]; then
    echo "Rebuilding Docker image..."
    docker compose -f "$SCRIPT_DIR/docker-compose.yml" build
    echo "[OK] Image rebuilt"
fi

# Start the container
docker compose -f "$SCRIPT_DIR/docker-compose.yml" up -d

echo ""
echo "Waiting for container to be healthy..."
sleep 5

# Check health
STATUS=$(docker inspect --format='{{.State.Health.Status}}' duckduckgo-mcp 2>/dev/null || echo "not found")

if [[ "$STATUS" == "healthy" ]]; then
    echo "[OK] DuckDuckGo MCP Server is healthy at http://localhost:8000/mcp"
else
    echo "[WARN] Container status: $STATUS"
    echo "       Check logs with: docker logs duckduckgo-mcp"
fi

echo ""
echo "MCP endpoint: http://localhost:8000/mcp"
echo "To stop: ./stop.sh"
