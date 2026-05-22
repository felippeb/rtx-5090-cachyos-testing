#!/usr/bin/env bash
# Run Open WebUI connected to local llama-server on CachyOS
# Access at http://localhost:8080
#
# CachyOS-specific notes:
#   - Uses --network host so container sees localhost:<llama_port> directly
#   - llama-server must bind to 0.0.0.0 (not 127.0.0.1)
#   - No OPENAI_API_KEYS set — llama.cpp doesn't require auth
#
# Usage: ./docker.sh [llama_port]
#   llama_port: port llama-server is listening on (default: 10500)
#
# Author: felippeburk | License: MIT

set -e

LLAMA_PORT="${1:-10500}"
WEBUI_PORT=8080

echo "Starting Open WebUI..."
echo "  Web UI:     http://localhost:${WEBUI_PORT}"
echo "  API target: http://localhost:${LLAMA_PORT}/v1"
echo ""

# Remove existing container if it exists
docker rm -f open-webui 2>/dev/null || true

docker run -d \
    --network host \
    --name open-webui \
    --volume open-webui:/app/backend/data \
    --restart always \
    -e OPENAI_API_BASE_URLS="http://localhost:${LLAMA_PORT}/v1" \
    -e OLLAMA_ENABLE=false \
    -e WEBUI_AUTH=true \
    -e ENABLE_SIGNUP=true \
    -e CORS_ALLOW_ORIGIN="*" \
    -e SCARF_NO_ANALYTICS=true \
    -e DO_NOT_TRACK=true \
    -e ANONYMIZED_TELEMETRY=false \
    -e ENABLE_WEB_SEARCH=true \
    -e WEB_SEARCH_ENGINE=duckduckgo \
    ghcr.io/open-webui/open-webui:main

echo ""
echo "Open WebUI running at http://localhost:${WEBUI_PORT}"
echo "Connected to llama-server at localhost:${LLAMA_PORT}"
echo "Web search enabled (DuckDuckGo)"
echo ""
echo "To stop: ./stop.sh"
