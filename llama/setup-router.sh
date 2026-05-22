#!/usr/bin/env bash
# Router mode setup — llama.cpp native model switching (no Ollama/LM Studio needed)
# Installs to /opt/llama-router/, config at /opt/router-config/models.ini
# Models stay in their existing locations, referenced by absolute path in the INI.
#
# Usage: sudo bash setup-router.sh [--update] [--test] [--add-model REPO:FILE]
#
# --update        Rebuild llama.cpp + regenerate config (skip model downloads)
# --test          Install to /opt/llama-router-test/ on port 10506
# --add-model     Download a small model for quick switching (e.g. unsloth/gemma-3-1b-it-GGUF:gemma-3-1b-it-Q4_K_M.gguf)

set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────
UPDATE_MODE=0
TEST_MODE=0
declare -a EXTRA_MODELS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --update)     UPDATE_MODE=1; shift ;;
        --test)       TEST_MODE=1; shift ;;
        --add-model)
            [[ $# -ge 2 ]] || { echo "Missing value for --add-model" >&2; exit 1; }
            EXTRA_MODELS+=("$2"); shift 2 ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1 ;;
    esac
done

if [[ $TEST_MODE -eq 1 ]]; then
    LLAMA_DIR="/opt/llama-router-test"
    CONFIG_DIR="/opt/router-config-test"
    MODELS_DIR="/opt/router-models-test"
    SERVICE_NAME_SUFFIX="-test"
    SERVER_PORT=10506
else
    LLAMA_DIR="/opt/llama-router"
    CONFIG_DIR="/opt/router-config"
    MODELS_DIR="/opt/router-models"
    SERVICE_NAME_SUFFIX=""
    SERVER_PORT=10500
fi

LLAMA_REPO="https://github.com/ggml-org/llama.cpp.git"
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
        fail "nvidia-smi not found."
    fi
    local gpu_name
    gpu_name=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1 | xargs)
    ok "GPU: $gpu_name"

    info "Checking CUDA toolkit..."
    if [[ ! -x "$CUDA_COMPILER" ]]; then
        fail "CUDA toolkit not found at $CUDA_COMPILER"
    fi
    local cuda_ver
    cuda_ver=$($CUDA_COMPILER --version | grep -oP 'release \K[0-9.]+' || echo "unknown")
    ok "CUDA: $cuda_ver"

    info "Installing build dependencies..."
    pacman -S --needed --noconfirm base-devel cmake git uv gcc14 aria2

    info "Setting up HuggingFace CLI venv at $HF_VENV..."
    if [[ ! -x "$HF_CLI" ]] || [[ $UPDATE_MODE -eq 1 ]]; then
        uv venv "$HF_VENV" --clear --quiet
        uv pip install --python "$HF_VENV/bin/python" "huggingface_hub[hf_transfer]>=0.25.0" --quiet
    fi
    ok "HuggingFace CLI ready"

    echo ""
}

# ─── Section 2: Build llama.cpp (mainline — router mode is included) ──
section_build() {
    info "=== Section 2: Build llama.cpp ==="

    local binary="$LLAMA_DIR/build/bin/llama-server"

    if [[ -x "$binary" ]] && [[ $UPDATE_MODE -eq 0 ]]; then
        # Check router mode support
        local help_out
        help_out=$(LD_LIBRARY_PATH="$(dirname "$binary")" "$binary" --help 2>&1) || true
        if echo "$help_out" | grep -q "models-dir"; then
            ok "Router-mode llama-server already built at $binary. Skipping."
            return
        else
            info "Existing build lacks router mode flags. Rebuilding."
        fi
    fi

    local WORK_DIR="$LLAMA_DIR"
    local NEEDS_CLONE=false

    if [[ -d "$LLAMA_DIR" ]] && [[ -d "$LLAMA_DIR/.git" ]]; then
        if [[ $UPDATE_MODE -eq 1 ]]; then
            ok "Update mode: pulling latest in $LLAMA_DIR"
        else
            local help_out
            help_out=$(LD_LIBRARY_PATH="$(dirname "$binary")" "$binary" --help 2>&1) || true
            if echo "$help_out" | grep -q "models-dir"; then
                ok "Router mode already supported. Skipping build."
                return
            fi
        fi
    else
        NEEDS_CLONE=true
        WORK_DIR="/tmp/llama-router-build"
    fi

    if [[ "$NEEDS_CLONE" == true ]]; then
        rm -rf "$WORK_DIR"
        info "Cloning llama.cpp (ggml-org/main)..."
        git clone --depth 1 "$LLAMA_REPO" "$WORK_DIR"
    fi

    pushd "$WORK_DIR" >/dev/null
    if [[ $UPDATE_MODE -eq 1 ]]; then
        git fetch origin master
        git reset --hard origin/master
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

    info "Building with $(nproc) threads..."
    cmake --build build --config Release --target llama-server -j"$(nproc)"

    if [[ ! -x "build/bin/llama-server" ]]; then
        popd >/dev/null
        fail "Build failed"
    fi

    if [[ "$WORK_DIR" != "$LLAMA_DIR" ]]; then
        info "Moving to $LLAMA_DIR..."
        popd >/dev/null
        rm -rf "$LLAMA_DIR"
        mv "$WORK_DIR" "$LLAMA_DIR"
    else
        popd >/dev/null
    fi

    ok "llama-server installed at $binary"

    # Verify router mode flags
    local help_out
    help_out=$(LD_LIBRARY_PATH="$(dirname "$binary")" "$binary" --help 2>&1) || true
    for flag in models-dir models-preset models-max models-autoload; do
        if echo "$help_out" | grep -q "$flag"; then
            ok "Flag --${flag} ✓"
        else
            warn "Flag --${flag} not found"
        fi
    done

    echo ""
}

# ─── Section 3: Download extra small models (optional) ────────────
section_extra_models() {
    if [[ ${#EXTRA_MODELS[@]} -eq 0 ]]; then
        info "=== Section 3: No extra models requested ==="
        echo ""
        return
    fi

    info "=== Section 3: Downloading extra models ==="
    mkdir -p "$MODELS_DIR"

    for entry in "${EXTRA_MODELS[@]}"; do
        local repo="${entry%%:*}"
        local file="${entry##*:}"
        if [[ ! -f "$MODELS_DIR/$file" ]]; then
            info "Downloading $repo:$file ..."
            HF_XET_HIGH_PERFORMANCE=1 "$HF_CLI" download "$repo" "$file" --local-dir "$MODELS_DIR"
        else
            ok "$file already exists"
        fi
    done

    echo ""
}

# ─── Section 4: Generate models.ini ──────────────────────────────
section_config() {
    info "=== Section 4: Generating $CONFIG_DIR/models.ini ==="

    mkdir -p "$CONFIG_DIR"

    # Discover all GGUF models (excluding mmproj and vocab files)
    declare -A model_paths   # name_without_ext -> path
    local search_dirs=(
        "/opt/models"
        "/opt/models-mtp"
        "/opt/models-gemma4-mtp"
        "$MODELS_DIR"
    )

    for dir in "${search_dirs[@]}"; do
        [[ -d "$dir" ]] || continue
        while IFS= read -r -d '' gguf; do
            local base
            base=$(basename "$gguf")
            # Skip mmproj and vocab files
            [[ "$base" == mmproj* ]] && continue
            [[ "$base" == ggml-vocab* ]] && continue
            local name="${base%.gguf}"
            model_paths["$name"]="$gguf"
        done < <(find "$dir" -maxdepth 2 -name "*.gguf" -type f -print0 2>/dev/null)
    done

    # Write the INI file
    local ini="$CONFIG_DIR/models.ini"
    {
        echo "# llama.cpp router mode — model presets"
        echo "# Section names must match GGUF filename (without .gguf extension)"
        echo "# Models are referenced by absolute path, no symlinks needed."
        echo ""

        for name in $(echo "${!model_paths[@]}" | tr ' ' '\n' | sort); do
            local path="${model_paths[$name]}"
            local size_mb
            size_mb=$(( $(stat --format=%s "$path" 2>/dev/null || echo 0) / 1048576 ))

            # Auto-tune ctx-size based on model size
            local ctx=8192
            local threads=16
            if (( size_mb < 2048 )); then
                ctx=8192; threads=8
            elif (( size_mb < 8192 )); then
                ctx=8192; threads=16
            else
                ctx=4096; threads=16
            fi

            echo "[$name]"
            echo "model = $path"
            echo "threads = $threads"
            echo "ctx-size = $ctx"
            echo "temp = 0.8"
            echo ""
        done
    } > "$ini"

    local count
    count=$(grep -c '^\[' "$ini" || true)
    ok "Wrote $ini with $count model sections"
    info "Models discovered:"
    for name in $(echo "${!model_paths[@]}" | tr ' ' '\n' | sort); do
        local size_mb
        size_mb=$(( $(stat --format=%s "${model_paths[$name]}" 2>/dev/null || echo 0) / 1048576 ))
        info "  $name (${size_mb}MB)"
    done

    echo ""
}

# ─── Section 5: Systemd Service ──────────────────────────────────
section_services() {
    info "=== Section 5: Install systemd service ==="

    local SCRIPT_DIR
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    local CONFIGS_DIR="$SCRIPT_DIR/services"
    local src="$CONFIGS_DIR/llama-server-router.service"
    local dest_name="llama-server-router${SERVICE_NAME_SUFFIX}.service"

    if [[ ! -f "$src" ]]; then
        fail "Service template not found: $src"
    fi

    sed -e "s|__USERNAME__|${SUDO_USER:-root}|g" \
        -e "s|/opt/llama-router|$LLAMA_DIR|g" \
        -e "s|/opt/router-config|$CONFIG_DIR|g" \
        -e "s|--port 10500|--port $SERVER_PORT|g" \
        "$src" > "/etc/systemd/system/$dest_name"

    ok "Installed /etc/systemd/system/$dest_name"

    systemctl daemon-reload

    info "Starting router on port $SERVER_PORT..."
    systemctl enable --now "$dest_name"

    sleep 3
    if systemctl is-active --quiet "$dest_name"; then
        ok "$dest_name is running on port $SERVER_PORT"
    else
        warn "Service failed to start. Check: journalctl -u $dest_name -n 30 --no-pager"
    fi

    echo ""
}

# ─── Main ────────────────────────────────────────────────────────
main() {
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║  llama.cpp Router Mode Setup                            ║"
    if [[ $TEST_MODE -eq 1 ]]; then
        echo "║  Target: $LLAMA_DIR  Port: $SERVER_PORT             ║"
    else
        echo "║  Target: $LLAMA_DIR                                     ║"
    fi
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""

    section_prerequisites
    section_build
    section_extra_models
    section_config
    section_services

    ok "═══════════════════════════════════════════════════════════"
    ok "Router mode setup complete!"
    ok "═══════════════════════════════════════════════════════════"
    echo ""
    info "Usage:"
    info "  1. Verify:     curl http://localhost:$SERVER_PORT/v1/models"
    info "  2. Chat API:   POST /v1/chat/completions with model=<name>"
    info "  3. Web UI:     open http://localhost:$SERVER_PORT in browser"
    info "  4. Add models: drop .gguf files, then:"
    info "                 sudo bash $0 --update"
    echo ""
    info "Stop:  sudo systemctl stop llama-server-router${SERVICE_NAME_SUFFIX}"
    echo ""
}

main "$@"
