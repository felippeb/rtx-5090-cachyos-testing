#!/usr/bin/env bash
# Install script for FLUX.1-schnell Image Generation Server
# Uses city96's GGUF-quantized FLUX.1-schnell with diffusers
# Targets ~/flux-venv for Python environment
# Run as: bash setup-flux.sh [--test|--update|--uninstall|--uninstall-all]
#
# --test          Install on port 10505 (safe to run alongside prod)
# --update        Refresh Python deps and service without touching model
# --uninstall     Stop service, remove systemd files, keep model and venv
# --uninstall-all Stop service, remove everything (systemd files, model, venv)

set -euo pipefail

UPDATE_MODE=0
TEST_MODE=0
UNINSTALL_MODE=0
UNINSTALL_ALL=0
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
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

if [[ $TEST_MODE -eq 1 ]]; then
    SERVICE_NAME_SUFFIX="-test"
    SERVER_PORT=10505
else
    SERVICE_NAME_SUFFIX=""
    SERVER_PORT=10501
fi

HOME_DIR="$HOME"
FLUX_VENV="$HOME_DIR/flux-venv"
FLUX_REPO="$HOME_DIR/repos/rtx-5090-cachyos-testing/flux-server"
MODEL_CACHE="$HOME_DIR/.cache/huggingface/hub/models--city96--FLUX.1-schnell-gguf"
MODEL_FILE="flux1-schnell-Q2_K.gguf"
SERVICE_FILE="vllm/services/flux-schnell.service"

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
    if [[ ! -x "/opt/cuda/bin/nvcc" ]]; then
        warn "nvcc not found at /opt/cuda/bin/nvcc"
    else
        local cuda_ver
        cuda_ver=$(/opt/cuda/bin/nvcc --version | grep -oP 'release \K[0-9.]+' || echo "unknown")
        ok "CUDA: $cuda_ver"
    fi

    info "Checking uv..."
    if ! command -v uv &>/dev/null; then
        fail "uv not found. Install: paru -S uv"
    fi
    ok "uv ready"

    echo ""
    info "Prerequisites complete. Press Enter to continue, or Ctrl+C to stop."
    read -r
}

# ─── Section 2: Python Virtual Environment ──────────────────────
section_venv() {
    info "=== Section 2: Python Virtual Environment ==="

    if [[ -d "$FLUX_VENV" ]] && [[ $UPDATE_MODE -eq 1 ]]; then
        info "Updating Python dependencies..."
        "$FLUX_VENV/bin/python" -m pip install --upgrade torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu124 --quiet 2>/dev/null || true
        "$FLUX_VENV/bin/python" -m pip install --upgrade diffusers accelerate transformers safetensors uvicorn fastapi pydantic --quiet 2>/dev/null || true
        ok "Python dependencies updated"
        return
    fi

    if [[ -d "$FLUX_VENV" ]]; then
        ok "venv already exists at $FLUX_VENV. Skipping."
        return
    fi

    info "Creating Python venv at $FLUX_VENV..."
    uv venv "$FLUX_VENV" --quiet

    info "Installing PyTorch (CUDA 12.4)..."
    "$FLUX_VENV/bin/python" -m pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu124 --quiet

    info "Installing diffusers and dependencies..."
    "$FLUX_VENV/bin/python" -m pip install diffusers accelerate transformers safetensors uvicorn fastapi pydantic --quiet

    ok "venv ready at $FLUX_VENV"

    echo ""
    info "venv complete. Press Enter to continue, or Ctrl+C to stop."
    read -r
}

# ─── Section 3: Download Model ──────────────────────────────────
section_model() {
    info "=== Section 3: Download FLUX.1-schnell GGUF ==="

    if [[ $UPDATE_MODE -eq 1 ]]; then
        ok "Update mode: skipping model files (no changes needed)"
        return
    fi

    if [[ -f "$MODEL_CACHE/snapshots/"*"/$MODEL_FILE" ]]; then
        warn "Model already downloaded. Skipping."
        return
    fi

    info "Downloading $MODEL_FILE from city96's GGUF repo..."
    info "This may take 10-30 minutes depending on your connection (~2.5 GB)."

    if command -v hf &>/dev/null; then
        HF_XET_HIGH_PERFORMANCE=1 hf download city96/FLUX.1-schnell-gguf "$MODEL_FILE" --local-dir "$MODEL_CACHE/snapshots/tmp"
        mkdir -p "$MODEL_CACHE/snapshots"
        mv "$MODEL_CACHE/snapshots/tmp/$MODEL_FILE" "$MODEL_CACHE/snapshots/"
        rm -rf "$MODEL_CACHE/snapshots/tmp"
    else
        info "HF CLI not found, using huggingface_hub Python API..."
        "$FLUX_VENV/bin/python" -c "
from huggingface_hub import snapshot_download
snapshot_download(
    repo_id='city96/FLUX.1-schnell-gguf',
    allow_patterns='$MODEL_FILE',
    local_dir='$MODEL_CACHE/snapshots/tmp',
)
import os, shutil
os.makedirs('$MODEL_CACHE/snapshots', exist_ok=True)
shutil.move('$MODEL_CACHE/snapshots/tmp/$MODEL_FILE', '$MODEL_CACHE/snapshots/')
shutil.rmtree('$MODEL_CACHE/snapshots/tmp', ignore_errors=True)
"
    fi

    ok "Model files in $MODEL_CACHE/snapshots/:"
    ls -lh "$MODEL_CACHE/snapshots/"

    echo ""
    info "Model download complete. Press Enter to continue, or Ctrl+C to stop."
    read -r
}

# ─── Section 4: Systemd Services ────────────────────────────────
section_services() {
    info "=== Section 4: Install systemd services ==="

    local SCRIPT_DIR
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    local SERVICE_TEMPLATE="$SCRIPT_DIR/../$SERVICE_FILE"
    local USERNAME
    USERNAME="${SUDO_USER:-$(logname 2>/dev/null || whoami)}"

    info "Enabling nvidia-persistenced..."
    systemctl enable --now nvidia-persistenced || warn "nvidia-persistenced may already be running"

    if [[ ! -f "$SERVICE_TEMPLATE" ]]; then
        warn "Service template not found at $SERVICE_TEMPLATE"
        return
    fi

    local svc_name="flux-schnell${SERVICE_NAME_SUFFIX}"
    local flux_path="$FLUX_VENV/bin/python"
    local server_script="$FLUX_REPO/flux_schnell_server.py"

    # Create the service file with proper paths
    cat > "/etc/systemd/system/${svc_name}.service" << EOF
[Unit]
Description=FLUX.1-schnell Image Generation Server (Port $SERVER_PORT)
After=network.target nvidia-persistenced.service
Wants=nvidia-persistenced.service

[Service]
Type=simple
User=$USERNAME
Group=$USERNAME

Environment="CUDA_VISIBLE_DEVICES=0"
Environment="PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True"
Environment="PYTHONUNBUFFERED=1"
Environment="FLUX_GGUF_PATH=$MODEL_CACHE/snapshots/$MODEL_FILE"
EnvironmentFile=/home/$USERNAME/.config/flux-server/.env
WorkingDirectory=$FLUX_REPO

ExecStart=$flux_path $server_script

Restart=always
RestartSec=10

LimitNOFILE=65536
MemoryMax=20G
OOMScoreAdjust=-400

[Install]
WantedBy=default.target
EOF

    ok "Installed /etc/systemd/system/${svc_name}.service"

    systemctl daemon-reload

    info "Starting FLUX server on port $SERVER_PORT..."
    systemctl enable --now "$svc_name"

    if systemctl is-active --quiet "$svc_name"; then
        ok "$svc_name is running on port $SERVER_PORT"
    else
        warn "Service failed to start. Check: journalctl -u $svc_name -n 20"
    fi

    info ""
    if [[ $TEST_MODE -eq 1 ]]; then
        info "Test instance running on port $SERVER_PORT"
        info "Health: curl http://localhost:$SERVER_PORT/health"
        info "Generate: curl -X POST http://localhost:$SERVER_PORT/generate -H 'Content-Type: application/json' -d '{\"prompt\":\"a cat\"}'"
    else
        info "To switch models later:"
        info "  ./scripts/service-switcher.sh e4b-flux       (E4B + FLUX dual-mode)"
        info "  ./scripts/service-switcher.sh qwen25-flux    (Qwen2.5-VL + FLUX dual-mode)"
        info ""
        info "Health: curl http://localhost:$SERVER_PORT/health"
        info "Generate: curl -X POST http://localhost:$SERVER_PORT/generate -H 'Content-Type: application/json' -d '{\"prompt\":\"a cat\"}'"
    fi

    echo ""
    info "Services installed. Press Enter to continue, or Ctrl+C to stop."
    read -r
}

# ─── Section 5: Uninstall ───────────────────────────────────────
section_uninstall() {
    info "=== Section 5: Uninstall ==="

    local svc_name="flux-schnell${SERVICE_NAME_SUFFIX}"
    local svc_file="/etc/systemd/system/${svc_name}.service"

    info "Stopping FLUX service..."
    sudo systemctl stop "$svc_name" 2>/dev/null || true
    sudo systemctl disable "$svc_name" 2>/dev/null || true

    if [[ -f "$svc_file" ]]; then
        info "Removing systemd service: $svc_file"
        sudo rm -f "$svc_file"
    fi

    sudo systemctl daemon-reload

    info "FLUX service removed."
    if [[ $UNINSTALL_ALL -eq 1 ]]; then
        info "Removing all FLUX data..."
        [[ -d "$FLUX_VENV" ]] && { info "Removing $FLUX_VENV"; rm -rf "$FLUX_VENV"; }
        info "Model files kept at $MODEL_CACHE (manual removal with: rm -rf $MODEL_CACHE)"
    else
        info "Model and venv kept. Remove manually with --uninstall-all."
    fi

    echo ""
    ok "FLUX uninstall complete!"
}

# ─── Section 6: OpenCode Config ─────────────────────────────────
section_opencode() {
    info "=== Section 6: OpenCode config update ==="

    info "To use FLUX.1-schnell with OpenCode, add this to ~/.config/opencode/opencode.json:"
    info ""
    cat <<'CONFIG'
  "flux": {
    "npm": "@ai-sdk/openai-compatible",
    "name": "FLUX.1-schnell",
    "options": {
      "baseURL": "http://localhost:10501"
    },
    "models": {
      "flux": {
        "name": "FLUX.1-schnell",
        "limit": { "context": 2048, "output": 2048 }
      }
    }
  }
CONFIG
    info ""
    info "Then set: \"model\": \"flux/flux\" for image generation"
    info ""
    info "Note: FLUX is an image generation model, not a chat model."
    info "Use it via the /generate endpoint or integrate with your app."
}

# ─── Main ────────────────────────────────────────────────────────
main() {
    if [[ $UNINSTALL_MODE -eq 1 ]]; then
        echo "============================================================"
        if [[ $UNINSTALL_ALL -eq 1 ]]; then
            echo "  FLUX.1-schnell Full Uninstaller"
            echo "  Removing: service, systemd files, venv"
        else
            echo "  FLUX.1-schnell Service Uninstaller"
            echo "  Removing: service, systemd files only"
        fi
        echo "============================================================"
        echo ""
        section_uninstall
        exit 0
    fi

    if [[ $UPDATE_MODE -eq 1 ]]; then
        echo "============================================================"
        echo "  FLUX.1-schnell Updater"
        echo "  Updating: Python deps, services"
        echo "============================================================"
    elif [[ $TEST_MODE -eq 1 ]]; then
        info "TEST MODE: installing on port $SERVER_PORT"
        echo "============================================================"
        echo "  FLUX.1-schnell Installer (TEST MODE)"
        echo "  Port: $SERVER_PORT"
        echo "============================================================"
    else
        echo "============================================================"
        echo "  FLUX.1-schnell Installer for CachyOS"
        echo "  GGUF: city96 Q2_K (~2.5 GB)"
        echo "  Port: $SERVER_PORT"
        echo "============================================================"
    fi
    echo ""

    section_prerequisites
    section_venv
    section_model
    section_services
    section_opencode

    echo ""
    if [[ $UPDATE_MODE -eq 1 ]]; then
        ok "FLUX.1-schnell Update complete!"
        echo ""
        info "Restart your server to pick up changes:"
        info "  ./scripts/service-switcher.sh e4b-flux"
    else
        ok "FLUX.1-schnell Installation complete!"
        echo ""
        if [[ $TEST_MODE -eq 1 ]]; then
            info "Test instance:"
            info "  1. Verify:  curl http://localhost:$SERVER_PORT/health"
            info "  2. Clean:   sudo systemctl stop --now flux-schnell-test"
        else
            info "Next steps:"
            info "  1. Verify:        curl http://localhost:$SERVER_PORT/health"
            info "  2. Generate:      curl -X POST http://localhost:$SERVER_PORT/generate -H 'Content-Type: application/json' -d '{\"prompt\":\"a sunset\"}'"
            info "  3. Switch to E4B+FLUX:  ./scripts/service-switcher.sh e4b-flux"
            info "  4. Run OpenCode:  opencode"
            info ""
            info "  Uninstall:  bash $0 --uninstall"
            info "  Full clean: bash $0 --uninstall-all"
        fi
    fi
    echo ""
}

main "$@"
