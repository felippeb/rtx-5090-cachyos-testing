#!/usr/bin/env bash
# NOTE: Gemma 4 MTP uses a different build (AtomicBot fork with TurboQuant).
# This script is NOT yet unified into setup-mtp.sh.
# Use this script for Gemma 4 MTP only.
#
# Full install script for llama.cpp (AtomicBot MTP) + Gemma 4 31B MTP on CachyOS + RTX 5090
# Builds llama.cpp from AtomicBot-ai/atomic-llama-cpp-turboquant (feature/turboquant-kv-cache branch)
# Downloads AtomicChat/gemma-4-31B-it-assistant-GGUF (assistant drafter head, ~0.5B)
# Downloads unsloth/gemma-4-31B-it-GGUF (target model, ~33B)
# Run as: sudo bash setup-gemma4-mtp.sh [--test|--update] [--hf-token TOKEN]
#
# --test   Install to /opt/gemma4-mtp-test/ on port 10502 (safe to run alongside prod)
# --update Refresh llama.cpp, models, and services without re-downloading unchanged files
# --hf-token TOKEN   Pass HF_TOKEN through sudo (needed for model downloads)

set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────
UPDATE_MODE=0
TEST_MODE=0
HF_TOKEN=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --test)   TEST_MODE=1; shift ;;
        --update) UPDATE_MODE=1; shift ;;
        --hf-token)
            [[ $# -ge 2 ]] || { echo "Missing value for --hf-token" >&2; exit 1; }
            HF_TOKEN="$2"
            shift 2
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

if [[ $TEST_MODE -eq 1 ]]; then
    LLAMA_DIR="/opt/gemma4-mtp-test"
    MODELS_DIR="/opt/gemma4-mtp-test/models"
    SERVICE_NAME_SUFFIX="-test"
    SERVER_PORT=10502
else
    TEST_MODE=0
    LLAMA_DIR="/opt/llama.cpp-gemma4-mtp"
    MODELS_DIR="/opt/models-gemma4-mtp"
    SERVICE_NAME_SUFFIX=""
    SERVER_PORT=10503
fi

ASSISTANT_MODEL_DIR="$MODELS_DIR/gemma4-31b-it-assistant"
ASSISTANT_MODEL_NAME="gemma-4-31B-it-assistant.Q4_K_M.gguf"
TARGET_MODEL_DIR="$MODELS_DIR/gemma4-31b-it"
TARGET_MODEL_NAME="gemma-4-31B-it-UD-Q4_K_XL.gguf"
HF_REPO_ASSISTANT="AtomicChat/gemma-4-31B-it-assistant-GGUF"
HF_REPO_TARGET="unsloth/gemma-4-31B-it-GGUF"
LLAMA_REPO="https://github.com/AtomicBot-ai/atomic-llama-cpp-turboquant.git"
LLAMA_BRANCH="feature/turboquant-kv-cache"
GPU_ARCH="120"  # RTX 5090 Blackwell sm_120
CUDA_COMPILER="/opt/cuda/bin/nvcc"
HF_VENV="/opt/hf-venv"
HF_CLI="$HF_VENV/bin/hf"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail()  { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }
has_mtp_head() {
    local binary="$1"
    local help_out
    help_out=$("$binary" --help 2>&1) || true
    echo "$help_out" | grep -q "mtp-head"
}

# ─── Section 1: Prerequisites ───────────────────────────────────
section_prerequisites() {
    info "=== Section 1: Prerequisites ==="

    if [[ $EUID -ne 0 ]]; then
        fail "This script requires root. Run: sudo bash $0"
    fi

    info "Checking NVIDIA driver..."
    if ! command -v nvidia-smi &>/dev/null; then
        fail "nvidia-smi not found. Install NVIDIA drivers first."
    fi
    local driver_ver
    driver_ver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)
    ok "NVIDIA driver: $driver_ver"

    local gpu_name
    gpu_name=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1 | xargs)
    ok "GPU: $gpu_name"

    info "Checking CUDA toolkit..."
    if [[ ! -x "$CUDA_COMPILER" ]]; then
        warn "nvcc not found at $CUDA_COMPILER"
        fail "CUDA toolkit is required"
    fi
    local cuda_ver
    cuda_ver=$($CUDA_COMPILER --version | grep -oP 'release \K[0-9.]+' || echo "unknown")
    ok "CUDA: $cuda_ver"

    info "Installing build dependencies..."
    pacman -S --needed --noconfirm base-devel cmake git uv gcc14 ninja

    info "Setting up HuggingFace CLI venv at $HF_VENV..."
    if ! command -v uv &>/dev/null; then
        fail "uv not found. Install: paru -S uv"
    fi
    if [[ ! -x "$HF_CLI" ]] || [[ $UPDATE_MODE -eq 1 ]]; then
        uv venv "$HF_VENV" --clear --quiet
        uv pip install --python "$HF_VENV/bin/python" "huggingface_hub[hf_transfer]>=0.25.0" --quiet
    fi
    ok "HuggingFace CLI ready at $HF_CLI"

    echo ""
    info "Prerequisites complete. Press Enter to continue, or Ctrl+C to stop."
    read -r
}

# ─── Section 2: Build llama.cpp with MTP + TurboQuant ──────────
section_build() {
    info "=== Section 2: Build llama.cpp (AtomicBot MTP + TurboQuant) ==="

    local binary="$LLAMA_DIR/build/bin/llama-server"

    if [[ -x "$binary" ]] && [[ $UPDATE_MODE -eq 0 ]]; then
        if has_mtp_head "$binary"; then
            ok "MTP-enabled llama-server already built at $binary. Skipping build."
            return
        else
            info "Existing build does not have --mtp-head support. Rebuilding."
        fi
    fi

    if [[ -d "$LLAMA_DIR" ]] && [[ -d "$LLAMA_DIR/.git" ]]; then
        if [[ $UPDATE_MODE -eq 1 ]]; then
            info "Checking for llama.cpp updates..."
            pushd "$LLAMA_DIR" >/dev/null
            local old_commit
            old_commit=$(git rev-parse HEAD)
            if ! git fetch --depth 1 origin "$LLAMA_BRANCH"; then
                warn "Git fetch failed, continuing with local copy"
                popd >/dev/null
                ok "llama.cpp unchanged, skipping build"
                return
            fi
            git reset --hard "origin/$LLAMA_BRANCH" || true
            local new_commit
            new_commit=$(git rev-parse HEAD)
            if [[ "$old_commit" == "$new_commit" ]]; then
                popd >/dev/null
                ok "llama.cpp unchanged, skipping build"
                return
            fi
            ok "llama.cpp updated ($old_commit -> $new_commit)"
            popd >/dev/null
        else
            info "llama.cpp already exists, checking for rebuild..."
            rm -rf "$LLAMA_DIR"
        fi
    else
        if [[ -d "$LLAMA_DIR" ]]; then
            rm -rf "$LLAMA_DIR"
        fi
    fi

    info "Cloning llama.cpp (AtomicBot, branch $LLAMA_BRANCH)..."
    rm -rf /tmp/llama-gemma4-mtp-clone
    git clone --branch "$LLAMA_BRANCH" --single-branch --recursive "$LLAMA_REPO" /tmp/llama-gemma4-mtp-clone
    mv /tmp/llama-gemma4-mtp-clone "$LLAMA_DIR"
    ok "Cloned to $LLAMA_DIR"

    pushd "$LLAMA_DIR" >/dev/null

    info "Configuring build..."
    CC=/usr/bin/gcc-14 CXX=/usr/bin/g++-14 \
    cmake -B build \
        -DCMAKE_BUILD_TYPE=Release \
        -DGGML_CUDA=ON \
        -DGGML_NATIVE=ON \
        -DGGML_CUDA_FA=ON \
        -DGGML_CUDA_FA_ALL_QUANTS=ON \
        -DCMAKE_CUDA_ARCHITECTURES="$GPU_ARCH" \
        -DCMAKE_CUDA_COMPILER="$CUDA_COMPILER" \
        -DCMAKE_CUDA_HOST_COMPILER="/usr/bin/g++-14" \
        -DLLAMA_FLASH_ATTN=ON

    info "Building with $(nproc) threads... (this takes 5-15 minutes)"
    cmake --build build --config Release --target llama-server --target llama-cli -j"$(nproc)"

    if [[ ! -x "$binary" ]]; then
        popd >/dev/null
        fail "Build failed - binary not found at $binary"
    fi

    ok "MTP-enabled llama-server installed at $binary"

    info "Verifying MTP head support in installed binary..."
    if has_mtp_head "$LLAMA_DIR/build/bin/llama-server"; then
        ok "MTP head support confirmed (--mtp-head is available)"
    else
        fail "MTP head support NOT detected in installed binary"
    fi

    popd >/dev/null
    echo ""
    info "Build complete. Press Enter to continue, or Ctrl+C to stop."
    read -r
}

# ─── Section 3: Download Models ─────────────────────────────────
section_models() {
    info "=== Section 3: Download Models ==="

    if [[ $UPDATE_MODE -eq 1 ]]; then
        ok "Update mode: checking existing models..."
    fi

    mkdir -p "$ASSISTANT_MODEL_DIR"
    mkdir -p "$TARGET_MODEL_DIR"

    # Download assistant drafter head (~337MB Q4_K_M)
    if [[ -f "$ASSISTANT_MODEL_DIR/$ASSISTANT_MODEL_NAME" ]]; then
        ok "Assistant model already exists at $ASSISTANT_MODEL_DIR/$ASSISTANT_MODEL_NAME. Skipping."
    else
        [[ -n "$HF_TOKEN" ]] || fail "HF_TOKEN is required for model downloads. Run: sudo bash $0 --hf-token YOUR_TOKEN"
        info "Downloading assistant drafter head ($ASSISTANT_MODEL_NAME, ~337 MB)..."
        info "This is the ~0.5B parameter drafter that predicts future tokens."
        HF_XET_HIGH_PERFORMANCE=1 HF_TOKEN="$HF_TOKEN" "$HF_CLI" download "$HF_REPO_ASSISTANT" "$ASSISTANT_MODEL_NAME" --local-dir "$ASSISTANT_MODEL_DIR"
    fi

    # Download target model (~18-19 GB)
    if [[ -f "$TARGET_MODEL_DIR/$TARGET_MODEL_NAME" ]]; then
        ok "Target model already exists: $TARGET_MODEL_NAME. Skipping."
    else
        [[ -n "$HF_TOKEN" ]] || fail "HF_TOKEN is required for model downloads. Run: sudo bash $0 --hf-token YOUR_TOKEN"
        info "Downloading target model ($TARGET_MODEL_NAME, ~18 GB)..."
        info "This may take 10-30 minutes depending on your connection."
        HF_XET_HIGH_PERFORMANCE=1 HF_TOKEN="$HF_TOKEN" "$HF_CLI" download "$HF_REPO_TARGET" "$TARGET_MODEL_NAME" --local-dir "$TARGET_MODEL_DIR"
    fi

    ok "Assistant model: $ASSISTANT_MODEL_DIR/$ASSISTANT_MODEL_NAME"
    ok "Target model: $TARGET_MODEL_DIR/$TARGET_MODEL_NAME"

    echo ""
    info "Model download complete. Press Enter to continue, or Ctrl+C to stop."
    read -r
}

# ─── Section 4: Systemd Services ────────────────────────────────
section_services() {
    info "=== Section 4: Install systemd services ==="

    local SCRIPT_DIR
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    local CONFIGS_DIR="$SCRIPT_DIR/services"

    info "Enabling nvidia-persistenced..."
    systemctl enable --now nvidia-persistenced || warn "nvidia-persistenced may already be running"

    for svc_base in llama-server-gemma4-mtp llama-server-gemma4-mtp-131k; do
        local src="$CONFIGS_DIR/${svc_base}.service"
        local dest_name="${svc_base}${SERVICE_NAME_SUFFIX}.service"
        if [[ -f "$src" ]]; then
            sed -e "s|/opt/llama.cpp-gemma4-mtp|$LLAMA_DIR|g" \
                -e "s|/opt/models-gemma4-mtp|$MODELS_DIR|g" \
                -e "s|--port 10503|--port $SERVER_PORT|g" \
                "$src" > "/etc/systemd/system/$dest_name"
            ok "Installed /etc/systemd/system/$dest_name"
        else
            warn "Service file not found: $src"
        fi
    done

    systemctl daemon-reload

    local default_svc="llama-server-gemma4-mtp${SERVICE_NAME_SUFFIX}"
    info "Starting Gemma 4 31B MTP mode (64K context, MTP speculative decoding, TurboQuant KV)..."
    systemctl enable --now "$default_svc"

    sleep 3
    if systemctl is-active --quiet "$default_svc"; then
        ok "$default_svc is running on port $SERVER_PORT"
    else
        warn "Service failed to start. Check: journalctl -u $default_svc -n 30 --no-pager"
    fi

    info ""
    if [[ $TEST_MODE -eq 1 ]]; then
        info "Test instance running on port $SERVER_PORT"
        info "To clean up: sudo systemctl stop --now $default_svc"
    else
        info "To switch modes later:"
        info "  ./scripts/service-switcher.sh gemma4-mtp         (64K context, MTP + TurboQuant)"
        info "  ./scripts/service-switcher.sh gemma4-mtp-131k    (131K context, MTP + TurboQuant)"
        info "  ./scripts/service-switcher.sh stop               (stop inference servers)"
    fi

    echo ""
    info "Services installed. Press Enter to continue, or Ctrl+C to stop."
    read -r
}

# ─── Section 5: OpenCode Config ─────────────────────────────────
section_opencode() {
    info "=== Section 5: OpenCode config update ==="

    info "To use Gemma 4 31B MTP with OpenCode, add this to ~/.config/opencode/opencode.json:"
    info ""
    cat <<'CONFIG'
  "gemma4-mtp": {
    "npm": "@ai-sdk/openai-compatible",
    "name": "Gemma 4 31B MTP (AtomicBot)",
    "options": { "baseURL": "http://localhost:10503/v1" },
    "models": {
      "gemma4-31b-mtp": {
        "name": "Gemma 4 31B MTP (64K)",
        "limit": { "context": 65536, "output": 8192 }
      }
    }
  }
CONFIG
    info ""
    info 'Then set: "model": "gemma4-mtp/gemma4-31b-mtp"'
}

# ─── Main ────────────────────────────────────────────────────────
main() {
    if [[ $UPDATE_MODE -eq 1 ]]; then
        echo "╔══════════════════════════════════════════════════════════╗"
        echo "║  llama.cpp AtomicBot MTP + Gemma 4 31B Updater          ║"
        echo "║  Updating: llama.cpp (MTP+TurboQuant), services         ║"
        echo "╚══════════════════════════════════════════════════════════╝"
    elif [[ $TEST_MODE -eq 1 ]]; then
        info "TEST MODE: installing to $LLAMA_DIR on port $SERVER_PORT"
        echo "╔══════════════════════════════════════════════════════════╗"
        echo "║  llama.cpp AtomicBot MTP + Gemma 4 31B (TEST MODE)      ║"
        echo "║  Target: /opt/gemma4-mtp-test/  Port: 10502             ║"
        echo "╚══════════════════════════════════════════════════════════╝"
    else
        echo "╔══════════════════════════════════════════════════════════╗"
        echo "║  llama.cpp AtomicBot MTP + Gemma 4 31B Installer        ║"
        echo "║  Model: Gemma 4 31B-it + Assistant Drafter (MTP)        ║"
        echo "║  Target: /opt/llama.cpp-gemma4-mtp + /opt/models-gemma4 ║"
        echo "╚══════════════════════════════════════════════════════════╝"
    fi
    echo ""

    section_prerequisites
    section_build
    section_models
    section_services
    section_opencode

    echo ""
    if [[ $UPDATE_MODE -eq 1 ]]; then
        ok "═══════════════════════════════════════════════════════════"
        ok "Gemma 4 31B MTP Update complete!"
        ok "═══════════════════════════════════════════════════════════"
        info "Restart: ./scripts/service-switcher.sh gemma4-mtp"
    else
        ok "═══════════════════════════════════════════════════════════"
        ok "Gemma 4 31B MTP Installation complete!"
        ok "═══════════════════════════════════════════════════════════"
        echo ""
        if [[ $TEST_MODE -eq 1 ]]; then
            info "Test instance:"
            info "  1. Verify:  curl http://localhost:10502/v1/models"
            info "  2. Clean:   sudo systemctl stop --now llama-server-gemma4-mtp-test"
        else
            info "Next steps:"
            info "  1. Verify:     curl http://localhost:$SERVER_PORT/v1/models"
            info "  2. Switch:     ./scripts/service-switcher.sh gemma4-mtp"
            info "  3. Run OpenCode: opencode"
        fi
    fi
    echo ""
}

main "$@"
