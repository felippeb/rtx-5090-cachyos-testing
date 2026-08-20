#!/usr/bin/env bash
# mem0 local setup — one-shot reproducible bring-up for the self-hosted memory layer.
# Spins up:
#   1. llama-embed.service — llama-server embedding model (nomic-embed-text-v1.5) on :8080
#   2. mem0-api.service    — FastAPI wrapper over mem0.Memory on :8001 (LLM: llama.cpp :10500, embed: :8080)
#   3. ~/.config/opencode/mem0.jsonc — plugin config pointing at the local API
#
# Idempotent: safe to re-run; services use Restart=on-failure and are left running.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$SCRIPT_DIR/mem0-server"

LLAMA_BIN="${LLAMA_BIN:-$HOME/.local/share/rtx-testing/llama.cpp-nvfp4/build/bin/llama-server}"
MODELS_DIR="${RTX_MODELS:-$HOME/.local/share/rtx-testing/models}"
VENV_DIR="${MEM0_VENV:-$HOME/.local/share/rtx-testing/.venv-mem0}"
DATA_DIR="${MEM0_DATA_DIR:-$HOME/.local/share/rtx-testing/mem0}"
CONFIG_DEST="${MEM0_PLUGIN_CONFIG:-$HOME/.config/opencode/mem0.jsonc}"

EMBED_MODEL_DIR="$MODELS_DIR/nomic-embed-text-v1.5"
EMBED_MODEL_FILE="$EMBED_MODEL_DIR/nomic-embed-text-v1.5.Q8_0.gguf"
EMBED_REPO="nomic-ai/nomic-embed-text-v1.5-GGUF"
EMBED_PORT=8080
API_PORT=8001
LLM_PORT=10500

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail()  { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }

wait_http() {
    local url="$1" name="$2" retries=0
    while ! curl -sf "$url" >/dev/null 2>&1; do
        if (( retries >= 60 )); then
            fail "$name did not come up on $url"
        fi
        sleep 1
        retries=$((retries + 1))
    done
    ok "$name up at $url"
}

check_port_free() {
    local port="$1" name="$2"
    if lsof -i :"$port" >/dev/null 2>&1; then
        fail "Port $port already in use ($name). Cannot start."
    fi
}

ensure_binary() {
    [[ -x "$LLAMA_BIN" ]] || fail "llama-server not found at $LLAMA_BIN. Build or install it first."
}

ensure_embed_model() {
    if [[ ! -f "$EMBED_MODEL_FILE" ]]; then
        info "Downloading $EMBED_MODEL_FILE..."
        mkdir -p "$EMBED_MODEL_DIR"
        HF_XET_HIGH_PERFORMANCE=1 huggingface-cli download "$EMBED_REPO" \
            "$(basename "$EMBED_MODEL_FILE")" --local-dir "$EMBED_MODEL_DIR" ${HF_TOKEN:+--token "$HF_TOKEN"}
        ok "Downloaded embedding model"
    else
        ok "Embedding model exists: $EMBED_MODEL_FILE"
    fi
}

ensure_venv() {
    if [[ ! -x "$VENV_DIR/bin/uvicorn" ]]; then
        info "Creating venv + installing mem0ai/fastapi/uvicorn..."
        python3 -m venv "$VENV_DIR"
        "$VENV_DIR/bin/pip" install -q --upgrade pip
        "$VENV_DIR/bin/pip" install -q mem0ai fastapi uvicorn
        ok "Venv ready at $VENV_DIR"
    else
        ok "Venv exists at $VENV_DIR"
    fi
}

start_embed() {
    if systemctl --user is-active llama-embed >/dev/null 2>&1; then
        ok "llama-embed already running"
        return
    fi
    check_port_free "$EMBED_PORT" "embedding llama-server"
    info "Starting llama-embed (nomic-embed-text-v1.5) on :$EMBED_PORT..."
    systemd-run --user --unit=llama-embed \
        --property=Restart=on-failure \
        --property=RestartSec=5 \
        --property=Type=simple \
        --working-directory="$HOME" \
        --collect \
        "$LLAMA_BIN" \
        -m "$EMBED_MODEL_FILE" \
        --embeddings --pooling mean -c 2048 -ngl 99 -t 4 -tb 4 --no-warmup \
        --host 0.0.0.0 --port "$EMBED_PORT"
    wait_http "http://localhost:$EMBED_PORT/v1/models" "llama-embed"
}

start_api() {
    if systemctl --user is-active mem0-api >/dev/null 2>&1; then
        ok "mem0-api already running"
        return
    fi
    check_port_free "$API_PORT" "mem0 API"
    info "Starting mem0-api on :$API_PORT (LLM :$LLM_PORT, embed :$EMBED_PORT)..."
    systemd-run --user --unit=mem0-api \
        --property=Restart=on-failure \
        --property=RestartSec=5 \
        --property=Type=simple \
        --working-directory="$APP_DIR" \
        --setenv=MEM0_DATA_DIR="$DATA_DIR" \
        --setenv=MEM0_LLM_BASE_URL="http://localhost:$LLM_PORT/v1" \
        --setenv=MEM0_EMB_BASE_URL="http://localhost:$EMBED_PORT/v1" \
        --collect \
        "$VENV_DIR/bin/uvicorn" app:app --host 0.0.0.0 --port "$API_PORT"
    wait_http "http://localhost:$API_PORT/health" "mem0-api"
}

write_plugin_config() {
    mkdir -p "$(dirname "$CONFIG_DEST")"
    cat > "$CONFIG_DEST" <<EOF
{
  "baseUrl": "http://localhost:$API_PORT",
  "similarityThreshold": 0.35,
  "maxMemories": 10
}
EOF
    ok "Wrote plugin config $CONFIG_DEST (baseUrl :$API_PORT)"
}

smoke_test() {
    info "Smoke test: POST a memory, then search..."
    local add_resp search_resp
    add_resp=$(curl -s -X POST "http://localhost:$API_PORT/memories" -H 'Content-Type: application/json' \
        -d '{"messages":[{"role":"user","content":"mem0 setup smoke test. The local memory stack uses llama.cpp for both the LLM and embeddings."}],"user_id":"setup-test"}')
    local id
    id=$(echo "$add_resp" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
    [[ -n "$id" ]] || fail "Smoke test: memory add failed. Response: $add_resp"
    ok "Memory added (id $id)"
    search_resp=$(curl -s -X POST "http://localhost:$API_PORT/search" -H 'Content-Type: application/json' \
        -d "{\"query\":\"what does the local memory stack use for embeddings?\",\"user_id\":\"setup-test\",\"limit\":3,\"threshold\":0.0}")
    echo "$search_resp" | grep -q '"results":\[{"id"' && ok "Search returned results" || warn "Search returned: $search_resp"
    curl -s -X DELETE "http://localhost:$API_PORT/memories/$id" >/dev/null
    ok "Smoke test passed"
}

ensure_binary
ensure_embed_model
ensure_venv
start_embed
start_api
write_plugin_config
smoke_test

echo ""
ok "mem0 local stack is live:"
info "  LLM:        http://localhost:$LLM_PORT (daily driver)"
info "  Embeddings: http://localhost:$EMBED_PORT (llama-embed.service)"
info "  mem0 API:   http://localhost:$API_PORT (mem0-api.service)"
info "  Plugin:     @fables092/opencode-mem0 in $SCRIPT_DIR/opencode.json"
info "  Config:     $CONFIG_DEST"
echo ""
info "Restart opencode to load the plugin. Logs:"
info "  journalctl --user -u llama-embed -f"
info "  journalctl --user -u mem0-api -f"