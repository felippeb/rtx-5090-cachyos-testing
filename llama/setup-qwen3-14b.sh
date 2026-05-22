#!/usr/bin/env bash
# Install script for Qwen3-14B on CachyOS + RTX 5090
# Uses official llama.cpp (no unsloth fork — 14B dense doesn't need unsloth's CUDA optimizations)
# Targets /opt/ for system-wide installation
# Run as: sudo bash setup-qwen3-14b.sh [--test|--update]
#
# --test    Install to /opt/qwen3-14b-test/ on port 10502 (safe to run alongside prod)
# --update  Refresh llama.cpp, huggingface_hub, and services without touching models

set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────
UPDATE_MODE=0
TEST_MODE=0
for arg in "$@"; do
    case "$arg" in
        --test)   TEST_MODE=1 ;;
        --update) UPDATE_MODE=1 ;;
    esac
done

if [[ $TEST_MODE -eq 1 ]]; then
    LLAMA_DIR="/opt/qwen3-14b-test/llama.cpp"
    MODELS_DIR="/opt/qwen3-14b-test/models"
    SERVICE_NAME_SUFFIX="-test"
    SERVER_PORT=10502
else
    TEST_MODE=0
    LLAMA_DIR="/opt/qwen3-14b/llama.cpp"
    MODELS_DIR="/opt/qwen3-14b/models"
    SERVICE_NAME_SUFFIX=""
    SERVER_PORT=10500
fi

MODEL_DIR="$MODELS_DIR/qwen3-14b"
MODEL_NAME="Qwen3-14B-Q4_K_M.gguf"
HF_REPO="Qwen/Qwen3-14B-GGUF"
LLAMA_REPO="https://github.com/ggerganov/llama.cpp.git"
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
    pacman -S --needed --noconfirm base-devel cmake git uv gcc14

    info "Setting up HuggingFace CLI venv at $HF_VENV..."
    if ! command -v uv &>/dev/null; then
        fail "uv not found. Install: paru -S uv"
    fi
    if [[ ! -x "$HF_CLI" ]] || [[ $UPDATE_MODE -eq 1 ]]; then
        if [[ $UPDATE_MODE -eq 1 ]]; then
            info "Updating huggingface_hub packages..."
        fi
        uv venv "$HF_VENV" --clear --quiet
        uv pip install --python "$HF_VENV/bin/python" "huggingface_hub[hf_transfer]>=0.25.0" --quiet
    fi
    ok "HuggingFace CLI ready at $HF_CLI"

    echo ""
    info "Prerequisites complete. Press Enter to continue, or Ctrl+C to stop."
    read -r
}

# ─── Section 2: Build llama.cpp (skip if already built) ─────────
section_build() {
    info "=== Section 2: Build llama.cpp ==="

    local binary="$LLAMA_DIR/build/bin/llama-server"

    if [[ -x "$binary" ]] && [[ $UPDATE_MODE -eq 0 ]]; then
        ok "llama-server already built at $binary. Skipping build."
        return
    fi

    if [[ -d "$LLAMA_DIR" ]] && [[ -d "$LLAMA_DIR/.git" ]]; then
        if [[ $UPDATE_MODE -eq 1 ]]; then
            info "Checking for llama.cpp updates..."
            pushd "$LLAMA_DIR" >/dev/null
            local old_commit
            old_commit=$(git rev-parse HEAD)
            if ! git fetch --depth 1 origin; then
                warn "Git fetch failed, continuing with local copy"
                popd >/dev/null
                ok "llama.cpp unchanged, skipping build"
                return
            fi
            git reset --hard origin/$(git rev-parse --abbrev-ref HEAD) || true
            local new_commit
            new_commit=$(git rev-parse HEAD)
            if [[ "$old_commit" == "$new_commit" ]]; then
                popd >/dev/null
                ok "llama.cpp unchanged, skipping build"
                return
            fi
            ok "llama.cpp updated ($old_commit → $new_commit)"
            popd >/dev/null
        else
            warn "$LLAMA_DIR already exists but no binary found. Re-cloning."
        fi
    else
        if [[ -d "$LLAMA_DIR" ]]; then
            rm -rf "$LLAMA_DIR"
        fi
        mkdir -p "$(dirname "$LLAMA_DIR")"
        info "Cloning official llama.cpp..."
        rm -rf /tmp/llama-cpp-clone
        git clone --depth 1 "$LLAMA_REPO" /tmp/llama-cpp-clone
        mv /tmp/llama-cpp-clone "$LLAMA_DIR"
        ok "Cloned to $LLAMA_DIR"
    fi

    info "Configuring build..."
    pushd "$LLAMA_DIR" >/dev/null

    if [[ -f "build/CMakeCache.txt" ]]; then
        local cached_source
        cached_source=$(grep -oP 'CMAKE_HOME_DIRECTORY:STRING=\K.*' build/CMakeCache.txt 2>/dev/null || echo "")
        if [[ "$cached_source" != "$LLAMA_DIR" ]]; then
            info "Removing stale CMake cache (points to $cached_source)..."
            rm -rf build
        fi
    fi

    CC=/usr/bin/gcc-14 CXX=/usr/bin/g++-14 \
    cmake -B build \
        -DGGML_CUDA=ON \
        -DGGML_NATIVE=ON \
        -DGGML_CUDA_FA=ON \
        -DGGML_CUDA_FA_ALL_QUANTS=ON \
        -DCMAKE_CUDA_ARCHITECTURES="$GPU_ARCH" \
        -DCMAKE_CUDA_COMPILER="$CUDA_COMPILER" \
        -DCMAKE_CUDA_HOST_COMPILER="/usr/bin/g++-14"

    info "Building with $(nproc) threads... (this takes 5-15 minutes)"
    cmake --build build -j"$(nproc)"

    if [[ ! -x "$binary" ]]; then
        fail "Build failed - binary not found at $binary"
    fi

    info "Verifying CUDA backend..."
    local version_output
    version_output=$("$binary" --version 2>&1 || true)
    if echo "$version_output" | grep -q "CUDA"; then
        ok "CUDA backend loaded"
    else
        warn "CUDA backend not detected in version output"
    fi

    popd >/dev/null
    echo ""
    info "Build complete. Press Enter to continue, or Ctrl+C to stop."
    read -r
}

# ─── Section 3: Download Model ──────────────────────────────────
section_model() {
    info "=== Section 3: Download Qwen3-14B ==="

    if [[ $UPDATE_MODE -eq 1 ]]; then
        ok "Update mode: skipping model files (no changes needed)"
        return
    fi

    mkdir -p "$MODEL_DIR"

    if [[ -f "$MODEL_DIR/$MODEL_NAME" ]]; then
        warn "Model already exists at $MODEL_DIR/$MODEL_NAME. Skipping download."
    else
        info "Downloading $MODEL_NAME (~7.1 GB)..."
        info "This may take 10-30 minutes depending on your connection."
        HF_XET_HIGH_PERFORMANCE=1 "$HF_CLI" download "$HF_REPO" "$MODEL_NAME" --local-dir "$MODEL_DIR"
    fi

    ok "Model files in $MODEL_DIR:"
    ls -lh "$MODEL_DIR/"

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

    for svc_base in llama-server-qwen3-14b; do
        local src="$CONFIGS_DIR/${svc_base}.service"
        local dest_name="${svc_base}${SERVICE_NAME_SUFFIX}.service"
        if [[ -f "$src" ]]; then
            sed -e "s|/opt/qwen3-14b/llama.cpp|$LLAMA_DIR|g" \
                -e "s|/opt/qwen3-14b/models|$MODELS_DIR|g" \
                -e "s|--port 10500|--port $SERVER_PORT|g" \
                "$src" > "/etc/systemd/system/$dest_name"
            ok "Installed /etc/systemd/system/$dest_name"
        else
            warn "Service file not found: $src"
        fi
    done

    systemctl daemon-reload

    local active_svc="llama-server-qwen3-14b${SERVICE_NAME_SUFFIX}"
    info "Starting server (131K context)..."
    systemctl enable --now "$active_svc"

    if systemctl is-active --quiet "$active_svc"; then
        ok "$active_svc is running on port $SERVER_PORT"
    else
        warn "Service failed to start. Check: journalctl -u $active_svc -n 20"
    fi

    info ""
    if [[ $TEST_MODE -eq 1 ]]; then
        info "Test instance running on port $SERVER_PORT"
        info "To clean up: sudo systemctl stop --now $active_svc"
    else
        info "To switch models later:"
        info "  ./scripts/service-switcher.sh qwen3-14b          (Qwen3-14B, 131K context)"
        info "  ./scripts/service-switcher.sh qwen-turbo         (Qwen3.6-27B, 131K context)"
    fi

    echo ""
    info "Services installed. Press Enter to continue, or Ctrl+C to stop."
    read -r
}

# ─── Section 5: OpenCode Config ─────────────────────────────────
section_opencode() {
    info "=== Section 5: OpenCode config update ==="

    info "To use Qwen3-14B with OpenCode, add this to ~/.config/opencode/opencode.json:"
    info ""
    cat <<'CONFIG'
  "qwen3-14b": {
    "npm": "@ai-sdk/openai-compatible",
    "name": "Qwen3-14B",
    "options": {
      "baseURL": "http://localhost:10500/v1"
    },
    "models": {
      "qwen3-14b": {
        "name": "Qwen3-14B",
        "limit": { "context": 131072, "output": 8192 }
      }
    }
  }
CONFIG
    info ""
    info 'Then set: "model": "qwen3-14b/qwen3-14b"'
}

# ─── Main ────────────────────────────────────────────────────────
main() {
    if [[ $UPDATE_MODE -eq 1 ]]; then
        echo "╔══════════════════════════════════════════════════════════╗"
        echo "║  llama.cpp + Qwen3-14B Updater                          ║"
        echo "║  Updating: llama.cpp, huggingface_hub, services         ║"
        echo "╚══════════════════════════════════════════════════════════╝"
    elif [[ $TEST_MODE -eq 1 ]]; then
        info "TEST MODE: installing to $LLAMA_DIR on port $SERVER_PORT"
        echo "╔══════════════════════════════════════════════════════════╗"
        echo "║  llama.cpp + Qwen3-14B Installer (TEST MODE)            ║"
        echo "║  Target: /opt/qwen3-14b-test/  Port: 10502              ║"
        echo "╚══════════════════════════════════════════════════════════╝"
    else
        echo "╔══════════════════════════════════════════════════════════╗"
        echo "║  llama.cpp + Qwen3-14B Installer for CachyOS            ║"
        echo "║  Target: /opt/qwen3-14b/ (official llama.cpp)           ║"
        echo "╚══════════════════════════════════════════════════════════╝"
    fi
    echo ""

    section_prerequisites
    section_build
    section_model
    section_services
    section_opencode

    echo ""
    if [[ $UPDATE_MODE -eq 1 ]]; then
        ok "═══════════════════════════════════════════════════════════"
        ok "Qwen3-14B Update complete!"
        ok "═══════════════════════════════════════════════════════════"
        echo ""
        info "Restart your server to pick up changes:"
        info "  ./scripts/service-switcher.sh qwen3-14b"
    else
        ok "═══════════════════════════════════════════════════════════"
        ok "Qwen3-14B Installation complete!"
        ok "═══════════════════════════════════════════════════════════"
        echo ""
        if [[ $TEST_MODE -eq 1 ]]; then
            info "Test instance:"
            info "  1. Verify:  curl http://localhost:10502/v1/models"
            info "  2. Clean:   sudo systemctl stop --now llama-server-qwen3-14b-test"
        else
            info "Next steps:"
            info "  1. Verify:        curl http://localhost:10500/v1/models"
            info "  2. Switch model:  ./scripts/service-switcher.sh qwen3-14b"
            info "  3. Run OpenCode:  opencode"
        fi
    fi
    echo ""
}

main "$@"
