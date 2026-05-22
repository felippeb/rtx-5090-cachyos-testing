#!/usr/bin/env bash
# DEPRECATED: Use setup-mtp.sh instead (unified MTP setup for all models)
#   sudo bash setup-mtp.sh --model 35b
#
# Full install script for llama.cpp (MTP build) + Qwen3.6-35B-A3B-MTP on CachyOS + RTX 5090
# Builds llama.cpp with MTP PR #22673 grafted on master
# Downloads havenoammo/Qwen3.6-35B-A3B-MTP-GGUF (UD-Q4_K_XL)
# Run as: sudo bash setup-qwen36-mtp.sh [--test|--update]
#
# --test    Install to /opt/llama-test/ on port 10502 (safe to run alongside prod)
# --update  Refresh llama.cpp (MTP build), services without touching models

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
    LLAMA_DIR="/opt/llama-test"
    MODELS_DIR="/opt/llama-test/models"
    SERVICE_NAME_SUFFIX="-test"
    SERVER_PORT=10502
else
    TEST_MODE=0
    LLAMA_DIR="/opt/llama.cpp"
    MODELS_DIR="/opt/models"
    SERVICE_NAME_SUFFIX=""
    SERVER_PORT=10500
fi

MODEL_DIR="$MODELS_DIR/qwen3.6-35b-a3b-mtp"
MODEL_NAME="Qwen3.6-35B-A3B-MTP-UD-Q4_K_XL.gguf"
HF_REPO_MTP="havenoammo/Qwen3.6-35B-A3B-MTP-GGUF"
LLAMA_REPO="https://github.com/ggml-org/llama.cpp.git"
PR_NUM="22673"
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
    if (( total_ram < 32 )); then
        warn "Only ${total_ram}GB RAM. MTP + CPU offload works best with 32GB+."
        warn "The script will continue but you may need to adjust -fitt."
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

# ─── Section 2: Build llama.cpp with MTP PR ─────────────────────
section_build() {
    info "=== Section 2: Build llama.cpp with MTP (PR #$PR_NUM) ==="

    local binary="$LLAMA_DIR/build/bin/llama-server"

    # Check if we already have an MTP-enabled build
    if [[ -x "$binary" ]] && [[ $UPDATE_MODE -eq 0 ]]; then
        if has_mtp "$binary"; then
            ok "MTP-enabled llama-server already built at $binary. Skipping build."
            return
        else
            info "Existing build does not have MTP support. Rebuilding."
        fi
    fi

    # Determine whether we need to clone fresh or can update in-place
    local WORK_DIR="$LLAMA_DIR"
    local NEEDS_CLONE=false

    if [[ -d "$LLAMA_DIR" ]] && [[ -d "$LLAMA_DIR/.git" ]] && [[ $UPDATE_MODE -eq 0 ]]; then
        info "Checking existing llama.cpp at $LLAMA_DIR..."
        # Check if MTP is already in the current build
        if has_mtp "$LLAMA_DIR/build/bin/llama-server"; then
            ok "MTP already supported in existing build at $LLAMA_DIR"
            return
        fi
        # Existing repo doesn't have MTP — clone fresh in /tmp and move
        warn "Existing build lacks MTP. Cloning fresh for MTP build."
        WORK_DIR="/tmp/llama-mtp-build"
        NEEDS_CLONE=true
    elif [[ ! -d "$LLAMA_DIR" ]] || [[ $UPDATE_MODE -eq 1 ]]; then
        NEEDS_CLONE=true
        WORK_DIR="/tmp/llama-mtp-build"
    fi

    if [[ "$NEEDS_CLONE" == true ]]; then
        rm -rf "$WORK_DIR"
        info "Cloning llama.cpp (ggml-org, full history for merge)..."
        git clone "$LLAMA_REPO" "$WORK_DIR"
    fi

    pushd "$WORK_DIR" >/dev/null

    # Fetch latest
    info "Fetching latest..."
    git fetch origin

    # Fetch PR as local branch
    info "Fetching MTP PR #$PR_NUM..."
    git fetch "origin" "pull/$PR_NUM/head:pr-$PR_NUM"

    # Check out master, then merge PR
    info "Checking out master..."
    git checkout master
    git reset --hard origin/master

    info "Merging PR #$PR_NUM (MTP support) on top..."
    if git merge --no-ff "pr-$PR_NUM" -m "Merge PR #$PR_NUM: llama + spec: MTP Support"; then
        ok "Merged successfully."
    else
        warn "Merge conflicted or unrelated histories. Trying --allow-unrelated-histories..."
        if git merge --no-ff --allow-unrelated-histories "pr-$PR_NUM" -m "Merge PR #$PR_NUM: llama + spec: MTP Support"; then
            ok "Merged with --allow-unrelated-histories."
        else
            warn "Merge still failed. Checking out PR branch directly and skipping master."
            git checkout "pr-$PR_NUM"
        fi
    fi

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

    # If we built in temp dir, move the build to the target dir
    if [[ "$WORK_DIR" != "$LLAMA_DIR" ]]; then
        info "Moving complete repo to $LLAMA_DIR..."
        popd >/dev/null
        rm -rf "$LLAMA_DIR"
        mv "$WORK_DIR" "$LLAMA_DIR"
    else
        popd >/dev/null
    fi

    ok "MTP-enabled llama-server installed at $binary"

    # Verify MTP support in installed binary
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
        info "Downloading $MODEL_NAME (~23 GB)..."
        info "This may take 10-30 minutes depending on your connection."
        HF_XET_HIGH_PERFORMANCE=1 "$HF_CLI" download "$HF_REPO_MTP" "$MODEL_NAME" --local-dir "$MODEL_DIR"
    fi

    ok "Model file downloaded:"
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

    for svc_base in llama-server-mtp llama-server-mtp-131k; do
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

    local turbo_svc="llama-server-mtp${SERVICE_NAME_SUFFIX}"
    info "Starting MTP mode (131K context, GPU+CPU hybrid, MTP speculative decoding)..."
    systemctl enable --now "$turbo_svc"

    sleep 3
    if systemctl is-active --quiet "$turbo_svc"; then
        ok "$turbo_svc is running on port $SERVER_PORT"
    else
        warn "Service failed to start. Check: journalctl -u $turbo_svc -n 30 --no-pager"
    fi

    info ""
    if [[ $TEST_MODE -eq 1 ]]; then
        info "Test instance running on port $SERVER_PORT"
        info "To clean up: sudo systemctl stop --now $turbo_svc"
    else
        info "To switch modes later:"
        info "  ./scripts/service-switcher.sh mtp         (131K context, MTP)"
        info "  ./scripts/service-switcher.sh mtp-131k    (131K context, MTP balanced)"
        info "  ./scripts/service-switcher.sh stop        (stop inference servers)"
        info ""
        info "To benchmark with mtp-bench.py:"
        info "  python3 mtp-bench.py --url http://localhost:$SERVER_PORT"
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
        info "To add the MTP model to your opencode config:"
        info "  Add a provider entry like this to ~/.config/opencode/opencode.json:"
        info ""
        cat <<'TEMPLATE'
    "llama-mtp": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "llama.cpp | Qwen3.6-35B-A3B MTP (MoE, Q4_K_XL)",
      "options": {
        "baseURL": "http://localhost:10500/v1"
      },
      "models": {
        "qwen3.6-35b-a3b-mtp": {
          "name": "Qwen3.6-35B-A3B MTP (131K)",
          "limit": { "context": 131072, "output": 32768 }
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
    if [[ $UPDATE_MODE -eq 1 ]]; then
        echo "╔══════════════════════════════════════════════════════════╗"
        echo "║  llama.cpp MTP + Qwen3.6-35B-A3B Updater               ║"
        echo "║  Updating: llama.cpp (MTP build), services              ║"
        echo "╚══════════════════════════════════════════════════════════╝"
    elif [[ $TEST_MODE -eq 1 ]]; then
        info "TEST MODE: installing to $LLAMA_DIR on port $SERVER_PORT"
        echo "╔══════════════════════════════════════════════════════════╗"
        echo "║  llama.cpp MTP + Qwen3.6-35B-A3B (TEST MODE)           ║"
        echo "║  Target: /opt/llama-test/  Port: 10502                  ║"
        echo "╚══════════════════════════════════════════════════════════╝"
    else
        echo "╔══════════════════════════════════════════════════════════╗"
        echo "║  llama.cpp MTP + Qwen3.6-35B-A3B Installer             ║"
        echo "║  Model: Qwen3.6-35B-A3B MTP (MoE, 35B total/3B active) ║"
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
        ok "MTP Update complete!"
        ok "═══════════════════════════════════════════════════════════"
        info "Restart: ./scripts/service-switcher.sh mtp"
    else
        ok "═══════════════════════════════════════════════════════════"
        ok "Installation complete!"
        ok "═══════════════════════════════════════════════════════════"
        echo ""
        if [[ $TEST_MODE -eq 1 ]]; then
            info "Test instance:"
            info "  1. Verify:  curl http://localhost:10502/v1/models"
            info "  2. Clean:   sudo systemctl stop --now llama-server-mtp-test"
        else
            info "Next steps:"
            info "  1. Verify:     curl http://localhost:$SERVER_PORT/v1/models"
            info "  2. Benchmark:  python3 mtp-bench.py"
            info "  3. Run:        opencode"
        fi
    fi
    echo ""
}

main "$@"
