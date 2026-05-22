#!/usr/bin/env bash
# Setup Pi coding agent configured for local MTP models (27B, 35B-A3B, Gemma 4 31B)
# Run as: bash setup-pi.sh [--update]

set -euo pipefail

UPDATE_MODE=0
for arg in "$@"; do
    case "$arg" in
        --update) UPDATE_MODE=1 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PI_DIR="$SCRIPT_DIR"
PI_SETTINGS="$PI_DIR/settings.json"
PI_EXTENSION="$PI_DIR/llama-local.ts"
PI_CACHE="$HOME/.pi/agent"
PI_PROJECT_SETTINGS="$REPO_DIR/.pi/settings.json"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail()  { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }

check_prerequisites() {
    info "Checking prerequisites..."

    if ! command -v node &>/dev/null; then
        warn "Node.js not found. Installing..."
        pacman -S --needed --noconfirm nodejs npm || true
    fi
    ok "Node.js: $(node --version)"

    if ! command -v npm &>/dev/null; then
        fail "npm not found. Install: pacman -S npm"
    fi
    ok "npm: $(npm --version)"
}

install_pi() {
    info "=== Installing Pi ==="

    if command -v pi &>/dev/null && [[ $UPDATE_MODE -eq 0 ]]; then
        ok "Pi already installed: $(pi --version 2>/dev/null || echo 'unknown version')"
        return
    fi

    info "Installing Pi via npm..."
    npm install -g @earendil-works/pi-coding-agent || {
        warn "npm install failed, trying curl installer..."
        curl -fsSL https://pi.dev/install.sh | sh
    }

    if command -v pi &>/dev/null; then
        ok "Pi installed: $(pi --version 2>/dev/null || echo 'installed')"
    else
        warn "Pi binary not in PATH. May need to refresh shell."
    fi
}

setup_project() {
    info "=== Configuring Pi for local llama.cpp ==="

    mkdir -p "$REPO_DIR/.pi"

    cat > "$PI_PROJECT_SETTINGS" << 'EOF'
{
  "defaultProvider": "llama-local",
  "defaultModel": "qwen3.6-27b-mtp-131k",
  "enabledModels": ["qwen3.6-27b-mtp-131k", "qwen3.6-35b-a3b-mtp-131k", "gemma4-31b-mtp-64k", "gemma4-31b-mtp-131k"],
  "compaction": {
    "enabled": true,
    "reserveTokens": 32768,
    "keepRecentTokens": 32768
  },
  "retry": {
    "enabled": true,
    "maxRetries": 3,
    "provider": {
      "timeoutMs": 300000
    }
  },
  "extensions": ["../pi/llama-local.ts"],
  "sessionDir": ".pi/sessions"
}
EOF

    ok "Project settings written to $PI_PROJECT_SETTINGS"
    ok "Extension: $PI_EXTENSION"
}

verify_setup() {
    info "=== Verification ==="

    if systemctl is-active --quiet llama-server-unsloth-mtp* 2>/dev/null; then
        ok "llama.cpp MTP service is running"
    else
        warn "No unsloth-mtp service detected running."
        info "Start one with: ./scripts/service-switcher.sh unsloth-mtp-131k"
    fi

    if curl -s http://localhost:10500/v1/models &>/dev/null; then
        ok "llama.cpp API responding on port 10500"
    else
        warn "llama.cpp not responding on port 10500"
        info "Make sure an unsloth-mtp service is running"
    fi
}

show_usage() {
    echo ""
    info "=== Usage ==="
    info "  cd $REPO_DIR"
    info "  pi                              # Start Pi (defaults to 27B MTP 131K)"
    info "  pi --model qwen3.6-35b-a3b-mtp-131k # Use 35B-A3B MTP 131K"
    info "  pi --model gemma4-31b-mtp-131k  # Use Gemma 4 31B MTP 131K (port 10503)"
    info "  Ctrl+P                          # Cycle between models mid-session"
    info ""
    info "Service switching (run one at a time):"
    info "  ./scripts/service-switcher.sh unsloth-mtp-131k   (27B/35B MTP on port 10500)"
    info "  ./scripts/service-switcher.sh gemma4-mtp         (Gemma 4 MTP on port 10503)"
}

main() {
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║  Pi Setup - MTP Models (27B, 35B-A3B, Gemma 4 31B)    ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""

    check_prerequisites
    install_pi
    setup_project
    verify_setup

    echo ""
    ok "═══════════════════════════════════════════════════════════"
    ok "Pi setup complete!"
    ok "═══════════════════════════════════════════════════════════"
    show_usage
}

main "$@"
