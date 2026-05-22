#!/usr/bin/env bash
# Install script for Qwen3.6-27B-Text-NVFP4-MTP on vLLM (CachyOS + RTX 5090)
# Downloads model and installs systemd services
# Run as: sudo bash setup-vllm-nvfp4-mtp.sh [--update]

set -euo pipefail

UPDATE_MODE=0
for arg in "$@"; do
    case "$arg" in
        --update) UPDATE_MODE=1 ;;
    esac
done

VLLM_VENV="/opt/vllm-venv"
VLLM_BIN="$VLLM_VENV/bin/vllm"
HF_CLI="$VLLM_VENV/bin/hf"
MODEL_REPO="sakamakismile/Qwen3.6-27B-Text-NVFP4-MTP"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail()  { echo -e "${RED}[FAIL]${NC} $*" ; exit 1; }

echo "╔══════════════════════════════════════════════════════════╗"
echo "║  vLLM + Qwen3.6-27B-Text-NVFP4-MTP Installer            ║"
echo "║  NVFP4 + MTP speculative decoding (n=3)                 ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# ─── Prerequisites ──────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    fail "This script requires root. Run: sudo bash $0"
fi

info "Checking NVIDIA driver..."
nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader | head -1

if [[ ! -x "$VLLM_BIN" ]]; then
    fail "vLLM not found at $VLLM_BIN"
fi
ok "vLLM: $("$VLLM_BIN" --version 2>/dev/null || echo 'unknown')"

if [[ ! -x "$HF_CLI" ]]; then
    fail "hf CLI not found at $HF_CLI"
fi

# Check for nvidia-modelopt (required for --quantization modelopt)
MODELOPT_VER=$("$VLLM_VENV/bin/python" -c "import nvidia_modelopt; print(nvidia_modelopt.__version__)" 2>/dev/null || echo "MISSING")
if [[ "$MODELOPT_VER" == "MISSING" ]]; then
    info "Installing nvidia-modelopt (required for NVFP4 modelopt quantization)..."
    "$VLLM_VENV/bin/pip" install nvidia-modelopt
    ok "nvidia-modelopt installed"
else
    ok "nvidia-modelopt: $MODELOPT_VER"
fi

# ─── Download Model ──────────────────────────────────────────────
if [[ $UPDATE_MODE -eq 0 ]]; then
    cached=$("$VLLM_VENV/bin/python" -c "
from huggingface_hub import scan_cache_dir
cache = scan_cache_dir()
for repo in cache.repos:
    if 'Qwen3.6-27B-Text-NVFP4-MTP' in repo.repo_id:
        print('cached')
        break
" 2>/dev/null || echo "")

    if [[ "$cached" == "cached" ]]; then
        ok "Model already cached"
    else
        info "Downloading $MODEL_REPO..."
        info "Press Enter to start, Ctrl+C to cancel."
        read -r
        HF_XET_HIGH_PERFORMANCE=1 "$HF_CLI" download "$MODEL_REPO"
        ok "Model downloaded"
    fi
fi

# ─── Install Services ────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIGS_DIR="$SCRIPT_DIR/services"

info "Enabling nvidia-persistenced..."
systemctl enable --now nvidia-persistenced || warn "nvidia-persistenced may already be running"

for svc_base in vllm-qwen3.6-27b-nvfp4-mtp vllm-qwen3.6-27b-nvfp4-mtp-turbo; do
    src="$CONFIGS_DIR/${svc_base}.service"
    if [[ -f "$src" ]]; then
        cp "$src" "/etc/systemd/system/${svc_base}.service.template"
        ok "Template: ${svc_base}.service"
    else
        warn "Service file not found: $src"
    fi
done

# Copy chat template (froggeric/Qwen-Fixed-Chat-Templates)
CHAT_TPL="$SCRIPT_DIR/../llama/chat_template.jinja"
if [[ -f "$CHAT_TPL" ]]; then
    cp "$CHAT_TPL" "/opt/models-mtp/chat_template.jinja"
    ok "Copied chat_template.jinja to /opt/models-mtp/"
fi

systemctl daemon-reload

echo ""
ok "═══════════════════════════════════════════════════════════"
ok "Setup complete! Services available via service-switcher.sh"
ok "═══════════════════════════════════════════════════════════"
echo ""
info "Start with:"
info "  ./scripts/service-switcher.sh nvfp4-mtp        (131K context, MTP n=3)"
info "  ./scripts/service-switcher.sh nvfp4-mtp-turbo  (256K context, MTP n=3)"
echo ""
info "Verify: curl http://localhost:10500/v1/models"
