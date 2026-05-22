#!/usr/bin/env bash
# Unified llama-swap setup — manages Qwen + FLUX behind a single proxy endpoint
# Installs to /opt/llama-swap/, config at /opt/llama-swap/config.yaml
# Auto-discovers text models from /opt/models* directories
# Run as: sudo bash setup-llama-swap.sh [--update] [--test] [--uninstall] [--uninstall-all]

set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────
UPDATE_MODE=0
TEST_MODE=0
UNINSTALL_MODE=0
UNINSTALL_ALL=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --update)          UPDATE_MODE=1; shift ;;
        --test)            TEST_MODE=1; shift ;;
        --uninstall)       UNINSTALL_MODE=1; shift ;;
        --uninstall-all)   UNINSTALL_MODE=1; UNINSTALL_ALL=1; shift ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ $TEST_MODE -eq 1 ]]; then
    CONFIG_DIR="/opt/llama-swap-test"
    SERVICE_NAME="llama-swap-test"
    PROXY_PORT=9293
else
    CONFIG_DIR="/opt/llama-swap"
    SERVICE_NAME="llama-swap"
    PROXY_PORT=9292
fi

LLAMA_BIN=""  # Will auto-discover
HF_VENV="/opt/hf-venv"
FLUX_VENV="$HOME/flux-venv"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FLUX_SCRIPT="$REPO_DIR/flux-server/flux_schnell_server.py"

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

# ─── Uninstall ────────────────────────────────────────────────────
do_uninstall() {
    info "=== Uninstalling llama-swap ==="

    if [[ $EUID -ne 0 ]]; then
        fail "This script requires root. Run: sudo bash $0"
    fi

    # Stop and disable service
    for svc in "$SERVICE_NAME"; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            info "Stopping $svc..."
            systemctl stop --now "$svc" 2>/dev/null || true
        fi
        if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
            info "Disabling $svc..."
            systemctl disable --now "$svc" 2>/dev/null || true
        fi
        rm -f "/etc/systemd/system/${svc}.service"
        info "Removed ${svc}.service"
    done

    systemctl daemon-reload

    if [[ $UNINSTALL_ALL -eq 1 ]]; then
        if [[ -d "$CONFIG_DIR" ]]; then
            info "Removing $CONFIG_DIR..."
            rm -rf "$CONFIG_DIR"
            ok "Removed config directory"
        fi
    else
        ok "Config kept at $CONFIG_DIR (use --uninstall-all to remove)"
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
        fail "nvidia-smi not found."
    fi
    local gpu_name
    gpu_name=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1 | xargs)
    ok "GPU: $gpu_name"

    info "Checking llama-swap binary..."
    if ! command -v llama-swap &>/dev/null; then
        warn "llama-swap not found. Installing from AUR..."
        pacman -S --needed --noconfirm llama-swap-bin || {
            warn "AUR install failed. Install manually: paru -S llama-swap-bin"
            fail "llama-swap is required"
        }
    fi
    local swap_ver
    swap_ver=$(llama-swap --version 2>&1 | head -1 || echo "installed")
    ok "llama-swap: $swap_ver"

    info "Discovering llama-server binary..."
    # Check known build locations
    for candidate in \
        "/opt/llama-mtp/build/bin/llama-server" \
        "/opt/llama.cpp/build/bin/llama-server" \
        "/home/felippeb/llama-cpp-build/build/bin/llama-server"; do
        if [[ -x "$candidate" ]]; then
            LLAMA_BIN="$candidate"
            break
        fi
    done
    if [[ -z "$LLAMA_BIN" ]]; then
        fail "llama-server not found. Build llama.cpp first."
    fi
    ok "llama-server: $LLAMA_BIN"

    echo ""
}

# ─── Section 2: Discover Models ─────────────────────────────────
section_discover_models() {
    info "=== Section 2: Discovering models ==="

    # Find all GGUF models (excluding mmproj and vocab files)
    declare -A discovered_models  # name -> path
    local search_dirs=(
        "/opt/models"
        "/opt/models-mtp"
        "/opt/models-gemma4-mtp"
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
            discovered_models["$name"]="$gguf"
        done < <(find "$dir" -maxdepth 2 -name "*.gguf" -type f -print0 2>/dev/null)
    done

    local count=${#discovered_models[@]}
    if (( count == 0 )); then
        warn "No GGUF models found in /opt/models*. Install some first."
        return
    fi

    ok "Discovered $count model(s):"
    for name in $(echo "${!discovered_models[@]}" | tr ' ' '\n' | sort); do
        local size_mb
        size_mb=$(( $(stat --format=%s "${discovered_models[$name]}" 2>/dev/null || echo 0) / 1048576 ))
        info "  $name (${size_mb}MB)"
    done

    # Check FLUX availability
    FLUX_AVAILABLE=false
    local FLUX_MODEL=""
    local flux_cache_dir="$HOME/.cache/huggingface/hub/models--city96--FLUX.1-schnell-gguf"
    if [[ -d "$flux_cache_dir" ]]; then
        # Find the actual GGUF file
        FLUX_MODEL=$(find "$flux_cache_dir" -name "flux1-schnell-*.gguf" -type f 2>/dev/null | head -1 || true)
    fi

    if [[ -n "$FLUX_MODEL" ]] && [[ -x "$FLUX_VENV/bin/python" ]]; then
        FLUX_AVAILABLE=true
        ok "FLUX available: $FLUX_MODEL"
    else
        warn "FLUX not fully available (model or venv missing)"
        info "Run: bash $REPO_DIR/flux-server/setup-flux.sh to set up image generation"
    fi

    echo ""
}

# ─── Section 3: Generate Config ──────────────────────────────────
section_config() {
    info "=== Section 3: Generating config ==="

    mkdir -p "$CONFIG_DIR"

    local ini="$CONFIG_DIR/config.yaml"

    # Build the YAML config
    local base_port=10500
    {
        cat << HEADER
# llama-swap config — auto-generated
# Docs: https://github.com/mostlygeek/llama-swap
logLevel: info
startPort: ${base_port}
healthCheckTimeout: 120
HEADER

        # FLUX env vars if available
        if [[ "$FLUX_AVAILABLE" == "true" ]]; then
            cat << ENV_BLOCK

env:
  FLUX_VENV: "${FLUX_VENV}"
  FLUX_SCRIPT: "${FLUX_SCRIPT}"
  FLUX_GGUF_PATH: "${FLUX_MODEL}"
  CUDA_VISIBLE_DEVICES: "0"
  PYTORCH_CUDA_ALLOC_CONF: "expandable_segments:True"
  PYTHONUNBUFFERED: "1"
ENV_BLOCK
        fi

        echo ""
        echo "models:"

        # Add each discovered model as a llama-server instance
        local model_names=()
        for name in $(echo "${!discovered_models[@]}" | tr ' ' '\n' | sort); do
            local path="${discovered_models[$name]}"
            local size_mb
            size_mb=$(( $(stat --format=%s "$path" 2>/dev/null || echo 0) / 1048576 ))

            # Auto-tune context size based on model size
            local ctx=131072
            if (( size_mb > 16384 )); then
                ctx=65536  # Large models get less context to fit in VRAM
            fi

            echo "  \"${name}\":"
            echo "    proxy: \"http://127.0.0.1:${base_port}\""
            echo "    cmd: |"
            echo "      ${LLAMA_BIN}"
            echo "      -m ${path}"
            echo "      -ngl 99"
            echo "      -fa on"
            echo "      -c ${ctx}"
            echo "      -np 1"
            echo "      -b 8192"
            echo "      -t 16"
            echo "      -tb 16"
            echo "      --temp 0.6"
            echo "      --top-p 0.95"
            echo "      --top-k 20"
            echo "      --min-p 0.0"
            echo "      --presence_penalty 1.0"
            echo "      --repeat_penalty 1.0"
            echo "      -rea off"
            echo "      -ctxcp 0"
            echo "      -ctk q8_0"
            echo "      -ctv q8_0"
            echo "      --host 0.0.0.0"
            echo "      --port \${PORT}"
            echo "    ttl: -1"
            echo ""

            model_names+=("$name")
        done

        # Add FLUX if available
        if [[ "$FLUX_AVAILABLE" == "true" ]]; then
            echo "  \"flux-schnell\":"
            echo "    proxy: \"http://127.0.0.1:$((base_port + 1))\""
            echo "    cmd: |"
            echo "      ${FLUX_VENV}/bin/python ${FLUX_SCRIPT}"
            echo "    checkEndpoint: /health"
            echo "    ttl: 300"
            echo ""

            model_names+=("flux-schnell")
        fi

        # Matrix section — defines concurrent sets
        echo "matrix:"
        echo "  vars:"
        for name in "${model_names[@]}"; do
            [[ "$name" == "flux-schnell" ]] && continue
            echo "    ${name}: ${name}"
        done
        if [[ "$FLUX_AVAILABLE" == "true" ]]; then
            echo "    flux: flux-schnell"
        fi

        echo "  sets:"
        if [[ "$FLUX_AVAILABLE" == "true" ]] && (( ${#model_names[@]} > 1 )); then
            # Build dual set string
            local text_models=()
            for name in "${model_names[@]}"; do
                [[ "$name" == "flux-schnell" ]] && continue
                text_models+=("$name")
            done
            if (( ${#text_models[@]} > 0 )); then
                echo "    dual: \"${text_models[0]} & flux-schnell\""
            fi
        else
            echo "    single: \"${model_names[0]:-qwen}\""
        fi

        echo ""
        echo "hooks:"
        echo "  preload:"
        for name in "${model_names[@]}"; do
            [[ "$name" == "flux-schnell" ]] && continue
            echo "    - ${name}"
            break  # Only preload first text model to save VRAM
        done

    } > "$ini"

    ok "Config written to $ini"
    info "Proxy: http://localhost:$PROXY_PORT"

    echo ""
}

# ─── Section 4: Systemd Service ──────────────────────────────────
section_services() {
    info "=== Section 4: Install systemd service ==="

    local SCRIPT_DIR
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    local CONFIGS_DIR="$SCRIPT_DIR/services"
    local src="$CONFIGS_DIR/llama-swap.service"
    local dest_name="${SERVICE_NAME}.service"

    if [[ ! -f "$src" ]]; then
        fail "Service template not found: $src"
    fi

    sed -e "s|__USERNAME__|${SUDO_USER:-root}|g" \
        -e "s|/opt/llama-swap|$CONFIG_DIR|g" \
        -e "s|--listen 0.0.0.0:9292|--listen 0.0.0.0:$PROXY_PORT|g" \
        "$src" > "/etc/systemd/system/$dest_name"

    ok "Installed /etc/systemd/system/$dest_name"

    systemctl daemon-reload

    # Stop conflicting services
    info "Stopping conflicting services..."
    for svc in llama-server llama-server-turbo flux-schnell; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            info "  Stopping $svc..."
            systemctl stop "$svc" 2>/dev/null || true
        fi
    done

    info "Starting $SERVICE_NAME on port $PROXY_PORT..."
    systemctl enable --now "$SERVICE_NAME"

    sleep 3
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        ok "$SERVICE_NAME is running on port $PROXY_PORT"
    else
        warn "Service failed to start. Check: journalctl -u $SERVICE_NAME -n 30 --no-pager"
    fi

    echo ""
}

# ─── Main ────────────────────────────────────────────────────────
main() {
    if [[ $UNINSTALL_MODE -eq 1 ]]; then
        do_uninstall
        exit 0
    fi

    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║  llama-swap Setup — Qwen + FLUX Proxy                   ║"
    if [[ $TEST_MODE -eq 1 ]]; then
        echo "║  Target: $CONFIG_DIR  Port: $PROXY_PORT           ║"
    else
        echo "║  Target: $CONFIG_DIR                               ║"
    fi
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""

    section_prerequisites
    section_discover_models
    section_config
    section_services

    ok "═══════════════════════════════════════════════════════════"
    ok "llama-swap setup complete!"
    ok "═══════════════════════════════════════════════════════════"
    echo ""
    info "Usage:"
    info "  Proxy:       http://localhost:$PROXY_PORT"
    info "  Chat API:    POST /v1/chat/completions (model=<name>)"
    info "  Models:      GET /v1/models"
    info "  Health:      GET /health"
    info "  UI:          http://localhost:$PROXY_PORT/ui"
    if [[ "$FLUX_AVAILABLE" == "true" ]]; then
        info "  FLUX direct: http://localhost:10501/generate"
    fi
    echo ""
    info "Switcher:  ./scripts/service-switcher.sh swap"
    info "Stop:      sudo systemctl stop $SERVICE_NAME"
    echo ""
}

main "$@"
