#!/usr/bin/env bash
# Setup script for Unsloth Studio as a user systemd service
# Runs WITHOUT sudo - installs to ~/.config/systemd/user/
#
# Usage: bash setup-unsloth-studio.sh [--update] [--uninstall]
#
# --update      Update the service file only (skip install)
# --uninstall   Stop and remove the user service

set -euo pipefail

UPDATE_MODE=0
UNINSTALL_MODE=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --update)     UPDATE_MODE=1; shift ;;
        --uninstall)  UNINSTALL_MODE=1; shift ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
DATA_DIR="$HOME/.local/share/unsloth"
UNSLOTH_BIN="$HOME/.unsloth/studio/unsloth_studio/bin/unsloth"
USER_SERVICE_DIR="$HOME/.config/systemd/user"
SERVICE_NAME="unsloth-studio"
PORT=8888

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail()  { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }

# ─── Uninstall ──────────────────────────────────────────────────
if [[ $UNINSTALL_MODE -eq 1 ]]; then
    info "Stopping $SERVICE_NAME..."
    systemctl --user stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl --user disable "$SERVICE_NAME" 2>/dev/null || true

    if [[ -f "$USER_SERVICE_DIR/${SERVICE_NAME}.service" ]]; then
        rm -f "$USER_SERVICE_DIR/${SERVICE_NAME}.service"
        ok "Removed $USER_SERVICE_DIR/${SERVICE_NAME}.service"
    fi

    systemctl --user daemon-reload 2>/dev/null || true
    ok "Unsloth Studio service removed."
    info "Unsloth Studio itself is still installed at $UNSLOTH_BIN"
    info "Data directory: $DATA_DIR"
    exit 0
fi

# ─── Section 1: Prerequisites ───────────────────────────────────
info "=== Section 1: Prerequisites ==="

if ! command -v nvidia-smi &>/dev/null; then
    fail "nvidia-smi not found. Install NVIDIA drivers first."
fi
gpu_name=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1 | xargs)
ok "GPU: $gpu_name"

# ─── Section 2: Install Unsloth ─────────────────────────────────
info "=== Section 2: Unsloth Studio ==="

if [[ -x "$UNSLOTH_BIN" ]]; then
    ok "Unsloth Studio already installed at $UNSLOTH_BIN"
else
    info "Installing Unsloth Studio..."
    curl -fsSL https://unsloth.ai/install.sh | sh
    if [[ -x "$UNSLOTH_BIN" ]]; then
        ok "Unsloth Studio installed."
    else
        fail "Installation failed. Binary not found at $UNSLOTH_BIN"
    fi
fi

if [[ $UPDATE_MODE -eq 0 ]]; then
    # Quick verify the binary works
    info "Verifying unsloth binary..."
    if "$UNSLOTH_BIN" --help &>/dev/null; then
        ok "unsloth binary OK"
    else
        warn "unsloth binary may have issues. Try: $UNSLOTH_BIN --help"
    fi
fi

# ─── Section 3: Install User Service ────────────────────────────
info "=== Section 3: Install user systemd service ==="

mkdir -p "$USER_SERVICE_DIR"

info "Writing $USER_SERVICE_DIR/${SERVICE_NAME}.service..."

sed "s|__USERNAME__|$(whoami)|g" \
    "$SCRIPT_DIR/services/unsloth-studio.service" \
    > "$USER_SERVICE_DIR/${SERVICE_NAME}.service"

ok "Service file installed."

# Enable linger so the service persists across logouts
info "Enabling linger for user $(whoami)..."
if loginctl enable-linger "$(whoami)" 2>/dev/null; then
    ok "Linger enabled. Service survives logout."
else
    warn "Could not enable linger (may need sudo)."
    warn "Run: sudo loginctl enable-linger $(whoami)"
    warn "Without linger, the service stops when you log out."
fi

systemctl --user daemon-reload
ok "systemd user daemon reloaded."

if [[ $UPDATE_MODE -eq 1 ]]; then
    # Restart if already running
    if systemctl --user is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        info "Restarting $SERVICE_NAME..."
        systemctl --user restart "$SERVICE_NAME"
        ok "Restarted."
    else
        info "Service not currently running. Start with: systemctl --user start $SERVICE_NAME"
    fi
else
    info "Enabling and starting $SERVICE_NAME..."
    systemctl --user enable --now "$SERVICE_NAME"

    sleep 3
    if systemctl --user is-active --quiet "$SERVICE_NAME"; then
        ok "$SERVICE_NAME is running on port $PORT"
    else
        warn "Service may still be starting. Check: journalctl --user -u $SERVICE_NAME -n 20"
    fi
fi

# ─── Section 4: Verify ──────────────────────────────────────────
info "=== Section 4: Verify ==="

info "Waiting for Unsloth Studio to be ready..."
WAIT=0
TIMEOUT=60
while [[ $WAIT -lt $TIMEOUT ]]; do
    if curl -sf "http://localhost:$PORT/api/health" >/dev/null 2>&1; then
        break
    fi
    sleep 2
    WAIT=$((WAIT + 2))
done

if curl -sf "http://localhost:$PORT/api/health" >/dev/null 2>&1; then
    ok "Health check passed: http://localhost:$PORT/api/health"
else
    warn "Health check not responding yet (studio may still be loading)"
fi

echo ""
ok "=== Setup Complete ==="
echo ""
info "Unsloth Studio: http://localhost:$PORT"
info "  Logs:    journalctl --user -u $SERVICE_NAME -f"
info "  Stop:    systemctl --user stop $SERVICE_NAME"
info "  Start:   systemctl --user start $SERVICE_NAME"
info "  Status:  systemctl --status $SERVICE_NAME"
echo ""
info "Open in browser: http://localhost:$PORT"
info "Pre-loaded model: Qwen3.6-27B MTP (Q4_K_XL, spec decode)"
info "Model path: /opt/models-mtp/qwen3.6-27b-mtp/Qwen3.6-27B-UD-Q4_K_XL.gguf"
echo ""
info "To uninstall: bash $0 --uninstall"
