#!/usr/bin/env bash
# DEPRECATED: Use setup-mtp.sh instead (unified MTP setup, builds from mainline)
#   sudo bash setup-mtp.sh --model 27b
#
# Full install script for llama.cpp (Unsloth MTP) + Qwen3.6-27B-MTP on CachyOS + RTX 5090
# Builds llama.cpp from unslothai/llama.cpp (mtp-clean branch)
# Downloads unsloth/Qwen3.6-27B-MTP-GGUF (UD-Q4_K_XL)
# Run as: sudo bash setup-qwen36-27b-mtp.sh [--unsloth|--test|--update]
#
# --unsloth   Install to /opt/llama.cpp-unsloth-am17an-mtp/ (side-by-side with existing llama.cpp)
# --test      Install to /opt/llama-test/ on port 10502 (safe to run alongside prod)
# --update    Refresh llama.cpp (MTP build), services without touching models

set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────
UPDATE_MODE=0
TEST_MODE=0
UNSLOTH_MODE=0
UNINSTALL_MODE=0
for arg in "$@"; do
    case "$arg" in
        --test)       TEST_MODE=1 ;;
        --update)     UPDATE_MODE=1 ;;
        --unsloth)    UNSLOTH_MODE=1 ;;
        --uninstall)  UNINSTALL_MODE=1; UNSLOTH_MODE=1 ;;
    esac
done

if [[ $UNSLOTH_MODE -eq 1 ]]; then
    TEST_MODE=0
    LLAMA_DIR="/opt/llama.cpp-unsloth-am17an-mtp"
    MODELS_DIR="/opt/models-unsloth-mtp"
    SERVICE_NAME_SUFFIX=""
    SERVER_PORT=10500
elif [[ $TEST_MODE -eq 1 ]]; then
    LLAMA_DIR="/opt/llama-test"
    MODELS_DIR="/opt/llama-test/models"
    SERVICE_NAME_SUFFIX="-test"
    SERVER_PORT=10502
else
    TEST_MODE=0
    UNSLOTH_MODE=0
    LLAMA_DIR="/opt/llama.cpp"
    MODELS_DIR="/opt/models"
    SERVICE_NAME_SUFFIX=""
    SERVER_PORT=10500
fi

MODEL_DIR="$MODELS_DIR/qwen3.6-27b-mtp-unsloth"
MODEL_NAME="Qwen3.6-27B-UD-Q4_K_XL.gguf"
MMPROJ_NAME="mmproj-F16.gguf"
HF_REPO_MTP="unsloth/Qwen3.6-27B-MTP-GGUF"
LLAMA_REPO="https://github.com/am17an/llama.cpp.git"
LLAMA_BRANCH="mtp-clean"
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
has_mtp() {
    local binary="$1"
    local lib_path
    lib_path=$(dirname "$binary")
    local help_out
    help_out=$(LD_LIBRARY_PATH="$lib_path" "$binary" --help 2>&1) || true
    echo "$help_out" | grep -q "spec-type"
}

# ─── Uninstall ────────────────────────────────────────────────────
do_uninstall() {
    info "=== Uninstalling Unsloth MTP ==="

    if [[ $EUID -ne 0 ]]; then
        fail "This script requires root. Run: sudo bash $0"
    fi

    if [[ "$LLAMA_DIR" != "/opt/llama.cpp-unsloth-am17an-mtp" ]]; then
        fail "Uninstall only supported for unsloth-mtp installation"
    fi

    # Stop and disable services
    local services=(
        "llama-server-unsloth-mtp"
        "llama-server-unsloth-mtp-131k"
    )

    for svc in "${services[@]}"; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            info "Stopping $svc..."
            systemctl stop --now "$svc" 2>/dev/null || true
        fi
        if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
            info "Disabling $svc..."
            systemctl disable --now "$svc" 2>/dev/null || true
        fi
        rm -f "/etc/systemd/system/${svc}.service"
        info "Removed $svc.service"
    done

    systemctl daemon-reload

    # Remove build directory
    if [[ -d "$LLAMA_DIR" ]]; then
        info "Removing $LLAMA_DIR..."
        rm -rf "$LLAMA_DIR"
        ok "Removed build directory"
    else
        ok "Build directory already removed"
    fi

    # Remove models directory
    if [[ -d "$MODEL_DIR" ]]; then
        info "Removing $MODEL_DIR..."
        rm -rf "$MODEL_DIR"
        ok "Removed model files"
    else
        ok "Model directory already removed"
    fi

    # Remove models-unsloth-mtp if empty
    if [[ -d "$MODELS_DIR" ]]; then
        if [[ -z "$(ls -A "$MODELS_DIR" 2>/dev/null)" ]]; then
            rmdir "$MODELS_DIR" 2>/dev/null || true
            ok "Removed empty $MODELS_DIR"
        fi
    fi

    ok "Uninstall complete"
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

    info "Checking system RAM..."
    local total_ram
    total_ram=$(free -g | awk '/^Mem:/{print $2}')
    if (( total_ram < 16 )); then
        warn "Only ${total_ram}GB RAM. MTP works best with 16GB+."
    fi
    ok "System RAM: ${total_ram}GB"

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
        uv venv "$HF_VENV" --clear --quiet
        uv pip install --python "$HF_VENV/bin/python" "huggingface_hub[hf_transfer]>=0.25.0" --quiet
    fi
    ok "HuggingFace CLI ready at $HF_CLI"

    echo ""
    info "Prerequisites complete. Press Enter to continue, or Ctrl+C to stop."
    read -r
}

# ─── Section 2: Build llama.cpp with MTP ────────────────────────
section_build() {
    info "=== Section 2: Build llama.cpp (Unsloth MTP) ==="

    local binary="$LLAMA_DIR/build/bin/llama-server"

    if [[ -x "$binary" ]] && [[ $UPDATE_MODE -eq 0 ]]; then
        if has_mtp "$binary"; then
            ok "MTP-enabled llama-server already built at $binary. Skipping build."
            return
        else
            info "Existing build does not have MTP support. Rebuilding."
        fi
    fi

    local NEEDS_CLONE=false
    local WORK_DIR="$LLAMA_DIR"

    if [[ -d "$LLAMA_DIR" ]] && [[ -d "$LLAMA_DIR/.git" ]] && [[ $UPDATE_MODE -eq 0 ]]; then
        if has_mtp "$LLAMA_DIR/build/bin/llama-server"; then
            ok "MTP already supported in existing build at $LLAMA_DIR"
            return
        fi
        warn "Existing build lacks MTP. Cloning fresh for MTP build."
        WORK_DIR="/tmp/llama-27b-mtp-build"
        NEEDS_CLONE=true
    elif [[ ! -d "$LLAMA_DIR" ]] || [[ $UPDATE_MODE -eq 1 ]]; then
        NEEDS_CLONE=true
        WORK_DIR="/tmp/llama-27b-mtp-build"
    fi

    if [[ "$NEEDS_CLONE" == true ]]; then
        rm -rf "$WORK_DIR"
        info "Cloning llama.cpp (am17an, branch $LLAMA_BRANCH)..."
        git clone --branch "$LLAMA_BRANCH" --single-branch "$LLAMA_REPO" "$WORK_DIR"
    fi

    pushd "$WORK_DIR" >/dev/null

    info "Configuring build..."
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
    cmake --build build --config Release --target llama-server -j"$(nproc)"

    if [[ ! -x "build/bin/llama-server" ]]; then
        popd >/dev/null
        fail "Build failed - binary not found"
    fi

    if [[ "$WORK_DIR" != "$LLAMA_DIR" ]]; then
        info "Moving complete repo to $LLAMA_DIR..."
        popd >/dev/null
        rm -rf "$LLAMA_DIR"
        mv "$WORK_DIR" "$LLAMA_DIR"
    else
        popd >/dev/null
    fi

    ok "MTP-enabled llama-server installed at $binary"

    info "Verifying MTP support in installed binary..."
    if has_mtp "$LLAMA_DIR/build/bin/llama-server"; then
        ok "MTP support confirmed (--spec-type mtp is available)"
    else
        fail "MTP support NOT detected in installed binary. Try: LD_LIBRARY_PATH=$LLAMA_DIR/build/bin $LLAMA_DIR/build/bin/llama-server --help | grep spec-type"
    fi

    echo ""
    info "Build complete. Press Enter to continue, or Ctrl+C to stop."
    read -r
}

# ─── Section 3: Download Model ──────────────────────────────────
section_model() {
    info "=== Section 3: Download Model ==="

    if [[ $UPDATE_MODE -eq 1 ]]; then
        ok "Update mode: skipping model files"
        return
    fi

    mkdir -p "$MODEL_DIR"

    if [[ -f "$MODEL_DIR/$MODEL_NAME" ]]; then
        ok "Model already exists at $MODEL_DIR/$MODEL_NAME. Skipping download."
    else
        info "Downloading $MODEL_NAME (~11 GB)..."
        info "This may take 10-30 minutes depending on your connection."
        HF_XET_HIGH_PERFORMANCE=1 "$HF_CLI" download "$HF_REPO_MTP" "$MODEL_NAME" --local-dir "$MODEL_DIR"
    fi

    if [[ -f "$MODEL_DIR/$MMPROJ_NAME" ]]; then
        ok "mmproj already exists. Skipping download."
    else
        info "Downloading $MMPROJ_NAME (~884 MB)..."
        HF_XET_HIGH_PERFORMANCE=1 "$HF_CLI" download "$HF_REPO_MTP" "$MMPROJ_NAME" --local-dir "$MODEL_DIR"
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

    for svc_base in llama-server-unsloth-mtp llama-server-unsloth-mtp-131k; do
        local src="$CONFIGS_DIR/${svc_base}.service"
        local dest_name="${svc_base}${SERVICE_NAME_SUFFIX}.service"
        if [[ -f "$src" ]]; then
            sed -e "s|/opt/llama.cpp|$LLAMA_DIR|g" \
                -e "s|/opt/models|$MODELS_DIR|g" \
                -e "s|--port 10500|--port $SERVER_PORT|g" \
                "$src" > "/etc/systemd/system/$dest_name"
            ok "Installed /etc/systemd/system/$dest_name"
        else
            warn "Service file not found: $src"
        fi
    done

    systemctl daemon-reload

    local default_svc="llama-server-unsloth-mtp${SERVICE_NAME_SUFFIX}"
    info "Starting 27B MTP mode (64K context, GPU+CPU hybrid, MTP spec decode, n-max=2)..."
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
        info "  ./scripts/service-switcher.sh unsloth-mtp         (64K context, MTP, n-max=2)"
        info "  ./scripts/service-switcher.sh unsloth-mtp-131k    (131K context, MTP, n-max=2)"
        info "  ./scripts/service-switcher.sh stop            (stop inference servers)"
    fi

    echo ""
    info "Services installed. Press Enter to continue, or Ctrl+C to stop."
    read -r
}

# ─── Section 5: OpenCode Setup ──────────────────────────────────
section_opencode() {
    info "=== Section 5: OpenCode (optional) ==="

    if command -v opencode &>/dev/null; then
        ok "OpenCode is already installed"
        info ""
        info "To add the 27B MTP model to your opencode config:"
        info "  Add a provider entry like this to ~/.config/opencode/opencode.json:"
        info ""
        cat <<'TEMPLATE'
    "llama-27b-mtp": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "llama.cpp | Qwen3.6-27B MTP (UD-Q4_K_XL)",
      "options": {
        "baseURL": "http://localhost:10500/v1"
      },
      "models": {
        "qwen3.6-27b-mtp": {
          "name": "Qwen3.6-27B MTP (64K)",
          "limit": { "context": 65536, "output": 8192 }
        }
      }
    }
TEMPLATE
    else
        info "Installing OpenCode..."
        pacman -S --needed --noconfirm nodejs npm || true
        mkdir -p /opt/npm-global
        npm config set prefix /opt/npm-global --global
        npm install -g opencode-ai --prefix /opt/npm-global 2>/dev/null || \
        npm install -g opencode-ai 2>/dev/null || \
        warn "OpenCode install failed. Install manually later."

        if [[ -f /opt/npm-global/bin/opencode ]]; then
            ok "OpenCode installed to /opt/npm-global/bin/opencode"
        fi
    fi

    info ""
    info "Add to your shell profile:"
    info "  echo 'fish_add_path /opt/npm-global/bin' >> ~/.config/fish/config.fish"
}

# ─── Main ────────────────────────────────────────────────────────
main() {
    if [[ $UNINSTALL_MODE -eq 1 ]]; then
        do_uninstall
        exit 0
    fi

    if [[ $UPDATE_MODE -eq 1 ]]; then
        echo "╔══════════════════════════════════════════════════════════╗"
        echo "║  llama.cpp Unsloth MTP + Qwen3.6-27B Updater           ║"
        echo "║  Updating: llama.cpp (MTP build), services             ║"
        echo "╚══════════════════════════════════════════════════════════╝"
    elif [[ $TEST_MODE -eq 1 ]]; then
        info "TEST MODE: installing to $LLAMA_DIR on port $SERVER_PORT"
        echo "╔══════════════════════════════════════════════════════════╗"
        echo "║  llama.cpp Unsloth MTP + Qwen3.6-27B (TEST MODE)       ║"
        echo "║  Target: /opt/llama-test/  Port: 10502                  ║"
        echo "╚══════════════════════════════════════════════════════════╝"
    else
        echo "╔══════════════════════════════════════════════════════════╗"
        echo "║  llama.cpp Unsloth MTP + Qwen3.6-27B Installer         ║"
        echo "║  Model: Qwen3.6-27B MTP (Dense, UD-Q4_K_XL)           ║"
        echo "║  Target: /opt/llama.cpp + /opt/models                   ║"
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
        ok "27B MTP Update complete!"
        ok "═══════════════════════════════════════════════════════════"
        info "Restart: ./scripts/service-switcher.sh unsloth-mtp"
    else
        ok "═══════════════════════════════════════════════════════════"
        ok "Installation complete!"
        ok "═══════════════════════════════════════════════════════════"
        echo ""
        if [[ $TEST_MODE -eq 1 ]]; then
            info "Test instance:"
            info "  1. Verify:  curl http://localhost:10502/v1/models"
            info "  2. Clean:   sudo systemctl stop --now llama-server-unsloth-mtp-test"
        else
            info "Next steps:"
            info "  1. Verify:     curl http://localhost:$SERVER_PORT/v1/models"
            info "  2. Run:        opencode"
        fi
    fi
    echo ""
}

main "$@"
