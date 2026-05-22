#!/usr/bin/env bash
# Install script for Gemma 4 E4B (llama.cpp, vision model)
# Uses bartowski's imatrix-calibrated GGUF with vision support
# Targets /opt/ for system-wide installation
# Run as: sudo bash setup-e4b.sh [--test|--update|--uninstall|--uninstall-all]
#
# --test          Install to /opt/e4b-test/ on port 10505 (safe to run alongside prod)
# --update        Refresh llama.cpp, huggingface_hub, and services without touching models
# --uninstall     Stop service, remove systemd files, keep model and llama.cpp
# --uninstall-all Stop service, remove everything (systemd files, models, llama.cpp build)
# --hf-token TOKEN   Pass HF_TOKEN through sudo (needed for model downloads)

set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────
UPDATE_MODE=0
TEST_MODE=0
UNINSTALL_MODE=0
UNINSTALL_ALL=0
HF_TOKEN=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --test)
            TEST_MODE=1
            shift
            ;;
        --update)
            UPDATE_MODE=1
            shift
            ;;
        --uninstall)
            UNINSTALL_MODE=1
            shift
            ;;
        --uninstall-all)
            UNINSTALL_MODE=1
            UNINSTALL_ALL=1
            shift
            ;;
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
    LLAMA_DIR="/opt/e4b-test/llama.cpp"
    MODELS_DIR="/opt/e4b-test/models"
    SERVICE_NAME_SUFFIX="-test"
    SERVER_PORT=10505
else
    TEST_MODE=0
    LLAMA_DIR="/opt/e4b/llama.cpp"
    MODELS_DIR="/opt/e4b/models"
    SERVICE_NAME_SUFFIX=""
    SERVER_PORT=10500
fi

MODEL_DIR="$MODELS_DIR/e4b"
MODEL_NAME="google_gemma-4-E4B-it-Q4_K_L.gguf"
MMPROJ_NAME="mmproj-F16.gguf"
HF_REPO="bartowski/google_gemma-4-E4B-it-GGUF"
HF_REPO_MMPROJ="unsloth/gemma-4-E4B-it-GGUF"
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
    info "=== Section 3: Download Gemma 4 E4B ==="

    if [[ $UPDATE_MODE -eq 1 ]]; then
        ok "Update mode: skipping model files (no changes needed)"
        return
    fi

    mkdir -p "$MODEL_DIR"

    if [[ -z "$HF_TOKEN" ]]; then
        fail "HF_TOKEN is required for model downloads. Run: sudo -E bash $0 or sudo bash $0 --hf-token YOUR_TOKEN"
    fi

    if [[ -f "$MODEL_DIR/$MODEL_NAME" ]]; then
        warn "Model already exists at $MODEL_DIR/$MODEL_NAME. Skipping download."
    else
        info "Downloading $MODEL_NAME (~6.3 GB, bartowski Q4_K_L imatrix)..."
        info "This may take 5-15 minutes depending on your connection."
        HF_XET_HIGH_PERFORMANCE=1 HF_TOKEN="$HF_TOKEN" "$HF_CLI" download "$HF_REPO" "$MODEL_NAME" --local-dir "$MODEL_DIR"
    fi

    if [[ -f "$MODEL_DIR/$MMPROJ_NAME" ]]; then
        warn "Vision projector already exists. Skipping download."
    else
        info "Downloading $MMPROJ_NAME (~150 MB) from unsloth repo..."
        HF_XET_HIGH_PERFORMANCE=1 HF_TOKEN="$HF_TOKEN" "$HF_CLI" download "$HF_REPO_MMPROJ" "$MMPROJ_NAME" --local-dir "$MODEL_DIR"
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
    local USERNAME
    USERNAME="${SUDO_USER:-$(logname 2>/dev/null || whoami)}"

    info "Enabling nvidia-persistenced..."
    systemctl enable --now nvidia-persistenced || warn "nvidia-persistenced may already be running"

    for svc_base in llama-server-e4b; do
        local src="$CONFIGS_DIR/${svc_base}.service"
        local dest_name="${svc_base}${SERVICE_NAME_SUFFIX}.service"
        if [[ -f "$src" ]]; then
            sed -e "s|/opt/e4b/llama.cpp|$LLAMA_DIR|g" \
                -e "s|/opt/e4b/models|$MODELS_DIR|g" \
                -e "s|--port 10500|--port $SERVER_PORT|g" \
                -e "s|__USERNAME__|$USERNAME|g" \
                "$src" > "/etc/systemd/system/$dest_name"
            ok "Installed /etc/systemd/system/$dest_name"
        else
            warn "Service file not found: $src"
        fi
    done

    systemctl daemon-reload

    # Patch installed service file for llama.cpp compatibility
    info "Patching installed service for llama.cpp compatibility..."
    if [[ -f "/etc/systemd/system/${svc_base}${SERVICE_NAME_SUFFIX}.service" ]]; then
        sed -i '/--vision-batch-size/d' "/etc/systemd/system/${svc_base}${SERVICE_NAME_SUFFIX}.service"
        sed -i 's|gemma-4-E4B-it-mmproj-F16.gguf|mmproj-F16.gguf|g' "/etc/systemd/system/${svc_base}${SERVICE_NAME_SUFFIX}.service"
        systemctl daemon-reload
        ok "Service patched"
    fi

    local active_svc="llama-server-e4b${SERVICE_NAME_SUFFIX}"
    info "Starting server (128K context, vision enabled, thinking mode)..."
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
        info "  ./scripts/service-switcher.sh e4b            (Gemma 4 E4B, 128K context)"
        info "  ./scripts/service-switcher.sh e4b-flux       (E4B + FLUX dual-mode)"
    fi

    echo ""
    info "Services installed. Press Enter to continue, or Ctrl+C to stop."
    read -r
}

# ─── Section 5: Uninstall ───────────────────────────────────────
section_uninstall() {
    info "=== Section 5: Uninstall ==="

    local USERNAME
    USERNAME="${SUDO_USER:-$(logname 2>/dev/null || whoami)}"

    info "Stopping E4B service..."
    sudo systemctl stop "llama-server-e4b${SERVICE_NAME_SUFFIX}" 2>/dev/null || true
    sudo systemctl disable "llama-server-e4b${SERVICE_NAME_SUFFIX}" 2>/dev/null || true

    local svc_file="/etc/systemd/system/llama-server-e4b${SERVICE_NAME_SUFFIX}.service"
    if [[ -f "$svc_file" ]]; then
        info "Removing systemd service: $svc_file"
        sudo rm -f "$svc_file"
    fi

    sudo systemctl daemon-reload

    info "E4B service removed."
    if [[ $UNINSTALL_ALL -eq 1 ]]; then
        info "Removing all E4B data..."
        [[ -d "/opt/e4b" ]] && { info "Removing /opt/e4b"; sudo rm -rf /opt/e4b; }
        [[ -d "/opt/e4b-test" ]] && { info "Removing /opt/e4b-test"; sudo rm -rf /opt/e4b-test; }
        info "All E4B data removed."
    else
        info "Models and llama.cpp build kept. Remove manually with --uninstall-all."
    fi

    echo ""
    ok "E4B uninstall complete!"
}

# ─── Section 6: OpenCode Config ─────────────────────────────────
section_opencode() {
    info "=== Section 6: OpenCode config update ==="

    info "To use Gemma 4 E4B with OpenCode, add this to ~/.config/opencode/opencode.json:"
    info ""
    cat <<'CONFIG'
  "e4b": {
    "npm": "@ai-sdk/openai-compatible",
    "name": "Gemma 4 E4B",
    "options": {
      "baseURL": "http://localhost:10500/v1"
    },
    "models": {
      "e4b": {
        "name": "Gemma 4 E4B-it",
        "limit": { "context": 131072, "output": 8192 }
      }
    }
  }
CONFIG
    info ""
    info 'Then set: "model": "e4b/e4b"'
}

# ─── Main ────────────────────────────────────────────────────────
main() {
    if [[ $UNINSTALL_MODE -eq 1 ]]; then
        echo "╔══════════════════════════════════════════════════════════╗"
        if [[ $UNINSTALL_ALL -eq 1 ]]; then
            echo "║  llama.cpp + Gemma 4 E4B Full Uninstaller               ║"
            echo "║  Removing: service, systemd files, models, build        ║"
        else
            echo "║  llama.cpp + Gemma 4 E4B Service Uninstaller            ║"
            echo "║  Removing: service, systemd files only                  ║"
        fi
        echo "╚══════════════════════════════════════════════════════════╝"
        echo ""
        section_uninstall
        exit 0
    fi

    if [[ $UPDATE_MODE -eq 1 ]]; then
        echo "╔══════════════════════════════════════════════════════════╗"
        echo "║  llama.cpp + Gemma 4 E4B Updater                        ║"
        echo "║  Updating: llama.cpp, huggingface_hub, services         ║"
        echo "╚══════════════════════════════════════════════════════════╝"
    elif [[ $TEST_MODE -eq 1 ]]; then
        info "TEST MODE: installing to $LLAMA_DIR on port $SERVER_PORT"
        echo "╔══════════════════════════════════════════════════════════╗"
        echo "║  llama.cpp + Gemma 4 E4B Installer (TEST MODE)          ║"
        echo "║  Target: /opt/e4b-test/  Port: 10505                    ║"
        echo "╚══════════════════════════════════════════════════════════╝"
    else
        echo "╔══════════════════════════════════════════════════════════╗"
        echo "║  llama.cpp + Gemma 4 E4B Installer for CachyOS          ║"
        echo "║  Target: /opt/e4b/ (bartowski Q4_K_L imatrix GGUF)      ║"
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
        ok "Gemma 4 E4B Update complete!"
        ok "═══════════════════════════════════════════════════════════"
        echo ""
        info "Restart your server to pick up changes:"
        info "  ./scripts/service-switcher.sh e4b"
    else
        ok "═══════════════════════════════════════════════════════════"
        ok "Gemma 4 E4B Installation complete!"
        ok "═══════════════════════════════════════════════════════════"
        echo ""
        if [[ $TEST_MODE -eq 1 ]]; then
            info "Test instance:"
            info "  1. Verify:  curl http://localhost:10505/v1/models"
            info "  2. Clean:   sudo systemctl stop --now llama-server-e4b-test"
        else
            info "Next steps:"
            info "  1. Verify:        curl http://localhost:10500/v1/models"
            info "  2. Switch model:  ./scripts/service-switcher.sh e4b"
            info "  3. Run OpenCode:  opencode"
            info ""
            info "  Uninstall:  sudo bash $0 --uninstall"
            info "  Full clean: sudo bash $0 --uninstall-all"
        fi
    fi
    echo ""
}

main "$@"
