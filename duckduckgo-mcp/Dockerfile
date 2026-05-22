# DuckDuckGo MCP Server - Dockerized with HTTP transport
# Includes [browser] extra for curl_cffi bot detection bypass

FROM python:3.13-slim

# Runtime dependencies for curl_cffi (bundled libcurl)
RUN apt-get update && \
    apt-get install -y --no-install-recommends libcurl4t64 && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY . /app

# Install package with browser extra for curl_cffi
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir ".[browser]"

# Run as non-root user
RUN useradd --create-home --shell /bin/bash mcp && \
    chown -R mcp:mcp /app
USER mcp

# Configuration via environment variables
ENV DDG_SAFE_SEARCH=OFF
ENV DDG_REGION=us-en
ENV MCP_HOST=0.0.0.0
ENV MCP_PORT=8000

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD python -c "import httpx; r = httpx.get('http://localhost:8000/mcp'); assert r.status_code < 500" || exit 1

# Streamable-HTTP transport for containerized MCP (stdio doesn't work in containers)
CMD ["sh", "-c", "python -m duckduckgo_mcp_server.server --transport streamable-http --host $MCP_HOST --port $MCP_PORT"]
