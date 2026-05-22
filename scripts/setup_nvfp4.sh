#!/usr/bin/env bash
# Setup script for NVFP4 quantization toolchain (CachyOS + RTX 5090)
# 1. Creates a uv-managed Python 3.12 venv with llm-compressor + deps
# 2. Symlinks the quantization script into the install dir's bin
# Run as: bash scripts/setup_nvfp4.sh [--update]
#
# After setup, quantize a model with:
#   ~/.local/nvfp4/bin/python scripts/nvfp4_quantize.py --model_name ...

set -euo pipefail

UPDATE_MODE=0
for arg in "$@"; do
    case "$arg" in
        --update) UPDATE_MODE=1 ;;
    esac
done

INSTALL_DIR="${1:-$HOME/.local/nvfp4}"
PYTHON_VERSION="3.12"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
UV_VENV="$INSTALL_DIR/.venv"

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
echo "║  NVFP4 Quantization Toolchain Setup                      ║"
echo "║  Install dir: $INSTALL_DIR"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# ─── Prerequisites ──────────────────────────────────────────────
if ! command -v uv &>/dev/null; then
    fail "uv not found. Install with: https://docs.astral.sh/uv/getting-started/installation/"
fi
ok "uv: $(uv --version)"

# ─── Create venv ────────────────────────────────────────────────
if [[ -d "$UV_VENV" ]] && [[ $UPDATE_MODE -eq 0 ]]; then
    ok "venv already exists at $UV_VENV"
    info "Pass --update to reinstall"
elif [[ -d "$UV_VENV" ]] && [[ $UPDATE_MODE -eq 1 ]]; then
    info "Reinstalling venv (--update)"
    rm -rf "$UV_VENV"
fi

if [[ ! -d "$UV_VENV" ]]; then
    info "Creating uv environment (Python $PYTHON_VERSION)..."
    uv venv "$UV_VENV" --python "$PYTHON_VERSION"
    ok "venv created"
fi

# ─── Install dependencies ──────────────────────────────────────
info "Installing llm-compressor, datasets, accelerate..."
uv pip install --python "$UV_VENV/bin/python" \
    "llmcompressor[all] @ git+https://github.com/vllm-project/llm-compressor.git@main" \
    datasets \
    accelerate

# ─── Symlink quantization script ──────────────────────────────
mkdir -p "$INSTALL_DIR/bin"
ln -sf "$SCRIPT_DIR/nvfp4_quantize.py" "$INSTALL_DIR/bin/nvfp4_quantize.py"
ok "Quantization script linked"

# ─── Verify ────────────────────────────────────────────────────
info "Verifying installation..."
"$UV_VENV/bin/python" -c "
import llmcompressor
print(f'llm-compressor version: {llmcompressor.__version__}')
import torch
print(f'torch version: {torch.__version__}')
print(f'CUDA available: {torch.cuda.is_available()}')
if torch.cuda.is_available():
    print(f'GPU: {torch.cuda.get_device_name(0)}')
    cap = torch.cuda.get_device_capability(0)
    print(f'Compute capability: SM{cap[0]*100+cap[1]}')
"

echo ""
ok "═══════════════════════════════════════════════════════════"
ok "Setup complete!"
ok "═══════════════════════════════════════════════════════════"
echo ""
info "Quantize a model:"
info "  $INSTALL_DIR/bin/python $REPO_DIR/scripts/nvfp4_quantize.py"
info "  --model_name <hf-model-or-path>"
info ""
info "Full options:"
info "  $INSTALL_DIR/bin/python $REPO_DIR/scripts/nvfp4_quantize.py --help"
