#!/usr/bin/env bash
# Setup: build llama-server, install, and optionally deploy a model.
# Usage: bash setup.sh [model-key]
#   Without args: build + config dirs only
#   With model key: build + config + download + start the model
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_DIR="$SCRIPT_DIR/config"
LLAMA_SRC="${LLAMA_SRC:-$HOME/llama.cpp-ggml}"
LLAMA_BIN_TARGET="$HOME/.local/bin/llama-server"
MODELS_DIR="${RTX_MODELS:-$HOME/.local/share/rtx-testing/models}"
RTX_CONFIG="${RTX_CONFIG:-$HOME/.config/rtx-testing}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail()  { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }

echo -e "${BOLD}RTX 5090 Local AI Setup${NC}"
echo "────────────────────────────────────────"

# ─── Prerequisites ────────────────────────────────────────────────
info "Checking prerequisites..."
nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null | head -1 || fail "nvidia-smi not found"
ok "GPU detected"
command -v cmake >/dev/null || fail "cmake not found. Install with: sudo pacman -S cmake"
command -v git >/dev/null || fail "git not found"
ok "Tools OK"

# ─── Build llama-server ───────────────────────────────────────────
if [[ -x "$LLAMA_SRC/build/bin/llama-server" ]]; then
    ok "llama-server already built at $LLAMA_SRC/build/bin/llama-server"
    info "Version: $("$LLAMA_SRC/build/bin/llama-server" --version 2>&1)"
elif [[ -x "$LLAMA_BIN_TARGET" ]]; then
    ok "llama-server already installed at $LLAMA_BIN_TARGET"
    info "Version: $("$LLAMA_BIN_TARGET" --version 2>&1)"
    LLAMA_SRC="$(dirname "$(dirname "$(readlink -f "$LLAMA_BIN_TARGET")")")"
else
    info "Building llama-server from ggml-org mainline..."
    if [[ ! -d "$LLAMA_SRC" ]]; then
        git clone --depth=1 https://github.com/ggml-org/llama.cpp.git "$LLAMA_SRC"
    fi
    cd "$LLAMA_SRC"
    cmake -B build -DGGML_CUDA=ON -DGGML_NATIVE=ON -DGGML_CUDA_FA=ON \
        -DGGML_CUDA_FA_ALL_QUANTS=ON -DLLAMA_CURL=ON \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_CUDA_ARCHITECTURES="120"
    cmake --build build -j"$(nproc)" --target llama-server
    ok "Build complete"
fi

# ─── Symlink to ~/.local/bin/ ─────────────────────────────────────
mkdir -p "$HOME/.local/bin"
if [[ ! -x "$LLAMA_BIN_TARGET" ]]; then
    ln -sf "$LLAMA_SRC/build/bin/llama-server" "$LLAMA_BIN_TARGET"
    ok "Symlinked llama-server to $LLAMA_BIN_TARGET"
else
    ok "llama-server already in ~/.local/bin/"
fi

# ─── Config dirs ──────────────────────────────────────────────────
mkdir -p "$RTX_CONFIG" "$MODELS_DIR"
if [[ ! -f "$RTX_CONFIG/chat_template.jinja" ]]; then
    cp "$CONFIG_DIR/chat_template.jinja" "$RTX_CONFIG/chat_template.jinja"
    ok "Copied chat template to $RTX_CONFIG/"
fi

# ─── Summary ───────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Setup Summary${NC}"
echo "────────────────────────────────────────"
echo -e "  llama-server: ${GREEN}$(~/.local/bin/llama-server --version 2>&1)${NC}"
echo -e "  Config:       $RTX_CONFIG/"
echo -e "  Models:       $MODELS_DIR/"

# ─── Deploy model (optional arg) ──────────────────────────────────
if [[ $# -ge 1 ]]; then
    echo ""
    echo "────────────────────────────────────────"
    info "Deploying model: $1"
    exec "$SCRIPT_DIR/scripts/switch-model.sh" "$1"
else
    echo -e "  Chat tempate: $RTX_CONFIG/chat_template.jinja"
    echo ""
        local power_limit
    power_limit=$(nvidia-smi --query-gpu=power.limit --format=csv,noheader 2>/dev/null | head -1 | cut -d. -f1 || echo "")
    if [[ -n "$power_limit" && "$power_limit" -ne 475 ]]; then
        warn "GPU power limit is ${power_limit}W — set to 475W for stable inference:"
        warn "  sudo nvidia-smi -pl 475"
    fi
    echo ""
    echo -e "  ${CYAN}Next steps:${NC}"
    echo "    bash setup.sh nvfp4-mtp     # Full setup + daily driver"
    echo "    ./scripts/switch-model.sh list  # See available models"
fi
echo ""
