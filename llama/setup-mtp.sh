#!/usr/bin/env bash
# User-space MTP setup — builds llama.cpp into ~/.local, no sudo required.
# Supports: Qwen3.8-27B NVFP4-MTP (converted), Qwen3.6-27B NVFP4-MTP, Qwopus3.6-27B v2 NVFP4-MTP,
#           Huihui-Qwen3.8-27B abliterated NVFP4-MTP (converted)
#
# Usage: bash llama/setup-mtp.sh [--model qwen38|nvfp4|qwopus|huihui] [--update] [--hf-token TOKEN]

set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────
MODEL="qwen38"
UPDATE_MODE=0
HF_TOKEN="${HF_TOKEN:-}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --model)
            [[ $# -ge 2 ]] || { echo "Missing value for --model" >&2; exit 1; }
            MODEL="$2"; shift 2 ;;
        --update)   UPDATE_MODE=1; shift ;;
        --hf-token)
            [[ $# -ge 2 ]] || { echo "Missing value for --hf-token" >&2; exit 1; }
            HF_TOKEN="$2"; shift 2 ;;
        *)
            echo "Unknown argument: $1" >&2
            echo "Usage: bash $0 [--model qwen38|nvfp4|qwopus|huihui] [--update] [--hf-token TOKEN]"
            exit 1 ;;
    esac
done

# Paths — everything under ~/.local, no sudo needed
# Build installs into ~/.local/share/rtx-testing/llama.cpp-nvfp4/
# Symlink at ~/.local/bin/llama-server points to the real binary.
LLAMA_DIR="$HOME/.local/share/rtx-testing/llama.cpp-nvfp4"
MODELS_DIR="$HOME/.local/share/rtx-testing/models"
LLAMA_BIN_LINK="$HOME/.local/bin/llama-server"

LLAMA_REPO="https://github.com/ggml-org/llama.cpp.git"
PR_NUM="22673"
GPU_ARCH="120"  # RTX 5090 Blackwell sm_120
CUDA_COMPILER="/opt/cuda/bin/nvcc"

HF_VENV_DIR="$HOME/.local/share/rtx-testing/.venv-hf"
HF_CLI="$HF_VENV_DIR/bin/hf"
# Conversion venv (torch + transformers) for NVFP4 safetensors -> GGUF
CONV_VENV_DIR="$HOME/.local/share/rtx-testing/.venv-conv"
CONV_PY="$CONV_VENV_DIR/bin/python"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail()  { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }

has_mtp() {
    local binary="$1"
    local lib_path
    lib_path=$(dirname "$binary")
    local help_out
    help_out=$(LD_LIBRARY_PATH="$lib_path" "$binary" --help 2>&1 || true)
    echo "$help_out" | grep -qi "spec-type\|draft-mtp\|spec-draft"
}

# ─── Model definitions ──────────────────────────────────────────
# For models sourced from safetensors (MODEL_SOURCE=safetensors), MODEL_HF_REPO
# is the HF repo with raw safetensors and MODEL_NAME is the converted output GGUF.
declare -A MODEL_HF_REPO MODEL_NAME MODEL_DIR_NAME MODEL_MMPROJ MODEL_MMPROJ_REPO MODEL_SOURCE

MODEL_HF_REPO[qwen38]="sakamakismile/Qwen3.8-27B-MTP-NVFP4"
MODEL_NAME[qwen38]="qwen3.8-27b-text-nvfp4-mtp.gguf"
MODEL_DIR_NAME[qwen38]="qwen3.8-27b-nvfp4-mtp"
MODEL_MMPROJ[qwen38]="mmproj-F16.gguf"
MODEL_MMPROJ_REPO[qwen38]="unsloth/Qwen3.8-27B-GGUF"
MODEL_SOURCE[qwen38]="safetensors"

MODEL_HF_REPO[nvfp4]="nilayparikh/Qwen3.6-27B-Text-NVFP4-MTP-GGUF"
MODEL_NAME[nvfp4]="qwen3.6-27b-text-nvfp4-mtp.gguf"
MODEL_DIR_NAME[nvfp4]="qwen3.6-27b-nvfp4-mtp"
MODEL_MMPROJ[nvfp4]="mmproj-F16.gguf"
MODEL_MMPROJ_REPO[nvfp4]="unsloth/Qwen3.6-27B-MTP-GGUF"

MODEL_HF_REPO[qwopus]="michaelw9999/Qwopus3.6-27B-v2-MTP-NVFP4-GGUF"
MODEL_NAME[qwopus]="Qwopus3.6-27B-v2-MTP-NVFP4-GGUF.gguf"
MODEL_DIR_NAME[qwopus]="qwopus3.6-27b-nvfp4-mtp"
MODEL_MMPROJ[qwopus]=""
MODEL_MMPROJ_REPO[qwopus]=""

MODEL_HF_REPO[huihui]="sakamakismile/Huihui-Qwen3.8-27B-abliterated-NVFP4"
MODEL_NAME[huihui]="huihui-qwen3.8-27b-abliterated-nvfp4-mtp.gguf"
MODEL_DIR_NAME[huihui]="huihui-qwen3.8-27b-abliterated-nvfp4-mtp"
MODEL_MMPROJ[huihui]="mmproj-F16.gguf"
MODEL_MMPROJ_REPO[huihui]="unsloth/Qwen3.8-27B-GGUF"
MODEL_SOURCE[huihui]="safetensors"

# ─── Section 1: Prerequisites ───────────────────────────────────
section_prerequisites() {
    info "=== Section 1: Prerequisites ==="

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
        fail "nvcc not found at $CUDA_COMPILER. Install CUDA toolkit."
    fi
    local cuda_ver
    cuda_ver=$($CUDA_COMPILER --version | grep -oP 'release \K[0-9.]+' || echo "unknown")
    ok "CUDA: $cuda_ver"

    info "Checking build dependencies..."
    local missing=()
    for pkg in cmake git uv gcc-15; do
        if ! command -v "$pkg" &>/dev/null; then
            missing+=("$pkg")
        fi
    done

    # Check base-devel and aria2 separately
    if [[ ! -d /usr/lib/pkgconfig ]] && ! command -v make &>/dev/null; then
        missing+=("base-devel")
    fi
    if ! command -v aria2c &>/dev/null; then
        missing+=("aria2")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        warn "Missing packages: ${missing[*]}"
        fail "Install them first, then re-run:"
        echo "  sudo pacman -S --needed base-devel cmake git uv gcc15 aria2"
    fi

    ok "All build dependencies present."

    info "Setting up HuggingFace CLI venv at $HF_VENV_DIR..."
    if ! command -v uv &>/dev/null; then
        fail "uv not found. Install: paru -S uv"
    fi
    if [[ ! -x "$HF_CLI" ]]; then
        uv venv "$HF_VENV_DIR" --quiet 2>/dev/null || python3 -m venv "$HF_VENV_DIR"
        uv pip install --python "$HF_VENV_DIR/bin/python" "huggingface_hub[hf_transfer]>=0.25.0" --quiet 2>/dev/null || \
            "$HF_VENV_DIR/bin/pip" install "huggingface_hub[hf_transfer]>=0.25.0" --quiet
    fi
    [[ -x "$HF_CLI" ]] || fail "Failed to install hf CLI"
    ok "HuggingFace CLI ready at $HF_CLI"

    echo ""
}

# ─── Section 2: Build llama.cpp with MTP PR ─────────────────────
section_build() {
    info "=== Section 2: Build llama.cpp (mainline + MTP PR #$PR_NUM) ==="

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

    if [[ -d "$LLAMA_DIR/.git" ]]; then
        if [[ $UPDATE_MODE -eq 1 ]]; then
            ok "Update mode: will pull latest in $LLAMA_DIR"
        elif has_mtp "$LLAMA_DIR/build/bin/llama-server"; then
            ok "MTP already supported in existing build at $LLAMA_DIR"
            return
        else
            warn "Existing build lacks MTP. Re-cloning fresh."
            rm -rf "$LLAMA_DIR"
            NEEDS_CLONE=true
        fi
    else
        NEEDS_CLONE=true
    fi

    if [[ "$NEEDS_CLONE" == true ]]; then
        mkdir -p "$(dirname "$LLAMA_DIR")"
        info "Cloning llama.cpp (ggml-org, full history for merge)..."
        git clone "$LLAMA_REPO" "$LLAMA_DIR"
    fi

    pushd "$LLAMA_DIR" >/dev/null

    git merge --abort 2>/dev/null || true

    info "Fetching latest..."
    git fetch origin

    info "Checking out master..."
    git checkout master 2>/dev/null || git checkout -b master origin/master
    git reset --hard origin/master

    if grep -rq "draft.mtp\|DRAFT_MTP\|spec_type.*mtp" src/ common/ 2>/dev/null; then
        ok "MTP support already in mainline. Skipping PR merge."
    else
        info "MTP not in current build. Fetching PR #$PR_NUM..."
        git fetch origin "pull/$PR_NUM/head:pr-$PR_NUM" || true

        if git merge --no-ff "pr-$PR_NUM" -m "Merge PR #$PR_NUM: MTP Support"; then
            ok "Merged successfully."
        else
            warn "Merge conflicted. Trying --allow-unrelated-histories..."
            if git merge --no-ff --allow-unrelated-histories "pr-$PR_NUM" -m "Merge PR #$PR_NUM: MTP Support"; then
                ok "Merged with --allow-unrelated-histories."
            else
                warn "Merge failed. Checking out PR branch directly."
                git checkout "pr-$PR_NUM"
            fi
        fi
    fi

    if [[ -f build/CMakeCache.txt ]]; then
        local cached_src
        cached_src=$(grep "CMAKE_HOME_DIRECTORY" build/CMakeCache.txt 2>/dev/null | cut -d= -f2 || true)
        if [[ -n "$cached_src" ]] && [[ "$cached_src" != "$LLAMA_DIR" ]]; then
            info "Stale CMake cache from $cached_src. Clearing..."
            rm -f build/CMakeCache.txt
        fi
    fi

    info "Configuring build..."
    CC=/usr/bin/gcc-15 CXX=/usr/bin/g++-15 \
    cmake -B build \
        -DGGML_CUDA=ON \
        -DGGML_NATIVE=ON \
        -DGGML_CUDA_FA=ON \
        -DGGML_CUDA_FA_ALL_QUANTS=ON \
        -DCMAKE_CUDA_ARCHITECTURES="$GPU_ARCH" \
        -DCMAKE_CUDA_COMPILER="$CUDA_COMPILER" \
        -DCMAKE_CUDA_HOST_COMPILER="/usr/bin/g++-15"

    info "Building with $(nproc) threads... (this takes 5-15 minutes)"
    cmake --build build --config Release --target llama-server -j"$(nproc)"

    if [[ ! -x "build/bin/llama-server" ]]; then
        popd >/dev/null
        fail "Build failed - binary not found"
    fi

    popd >/dev/null

    ok "MTP-enabled llama-server built at $binary"

    info "Verifying MTP support..."
    if has_mtp "$LLAMA_DIR/build/bin/llama-server"; then
        ok "MTP support confirmed (--spec-type available)"
    else
        fail "MTP support NOT detected."
    fi

    # Symlink to ~/.local/bin so switch-model.sh finds it
    mkdir -p "$HOME/.local/bin"
    ln -sf "$LLAMA_DIR/build/bin/llama-server" "$LLAMA_BIN_LINK"
    ok "Symlinked: $LLAMA_BIN_LINK -> $binary"

    # Copy chat template from config/ (source of truth) to build dir
    local SCRIPT_DIR
    SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
    local TEMPLATE_SRC="$SCRIPT_DIR/config/chat_template.jinja"
    if [[ -f "$TEMPLATE_SRC" ]]; then
        cp "$TEMPLATE_SRC" "$LLAMA_DIR/chat_template.jinja"
        ok "Copied chat_template.jinja to $LLAMA_DIR/"
    else
        # Fallback: copy from llama/ (legacy location)
        local LEGACY_SRC="$SCRIPT_DIR/llama/chat_template.jinja"
        if [[ -f "$LEGACY_SRC" ]]; then
            cp "$LEGACY_SRC" "$LLAMA_DIR/chat_template.jinja"
            ok "Copied chat_template.jinja (legacy fallback) to $LLAMA_DIR/"
        fi
    fi

    echo ""
}

# ─── Section 3: Download / Convert Models ───────────────────────
section_convert() {
    local m="$1"
    if [[ "${MODEL_SOURCE[$m]:-}" != "safetensors" ]]; then
        return 0
    fi

    local repo="${MODEL_HF_REPO[$m]}"
    local name="${MODEL_NAME[$m]}"
    local dir_name="${MODEL_DIR_NAME[$m]}"
    local model_dir="$MODELS_DIR/$dir_name"

    if [[ -f "$model_dir/$name" ]]; then
        ok "[$m] Converted GGUF already exists: $name. Skipping."
        return 0
    fi

    mkdir -p "$model_dir"

    local hf_token_args=()
    if [[ -n "$HF_TOKEN" ]]; then
        hf_token_args+=("--token" "$HF_TOKEN")
    fi

    info "[$m] Setting up conversion venv at $CONV_VENV_DIR..."
    if [[ ! -x "$CONV_PY" ]]; then
        uv venv "$CONV_VENV_DIR" --quiet 2>/dev/null || python3 -m venv "$CONV_VENV_DIR"
    fi
    if ! "$CONV_PY" -c "import torch, transformers, safetensors" 2>/dev/null; then
        info "[$m] Installing torch + transformers into conversion venv (~3GB)..."
        uv pip install --python "$CONV_PY" torch transformers safetensors --quiet
    fi
    "$CONV_PY" -c "import torch, transformers, safetensors" || fail "Conversion deps missing in $CONV_PY"

    local src_dir="$model_dir/source"
    rm -rf "$src_dir"
    mkdir -p "$src_dir"

    if [[ ! -f "$src_dir/config.json" ]]; then
        info "[$m] Downloading safetensors from $repo (~20GB, takes a while)..."
        HF_XET_HIGH_PERFORMANCE=1 "$HF_CLI" download "$repo" --local-dir "$src_dir" "${hf_token_args[@]}"
    fi

    local converter="$LLAMA_DIR/convert_hf_to_gguf.py"
    if [[ ! -f "$converter" ]]; then
        fail "Converter not found: $converter (build llama.cpp first)"
    fi

    info "[$m] Converting NVFP4 safetensors -> GGUF (this takes several minutes)..."
    HF_TOKEN="${HF_TOKEN:-}" "$CONV_PY" "$converter" "$src_dir" \
        --outfile "$model_dir/$name" \
        --outtype auto

    if [[ ! -f "$model_dir/$name" ]]; then
        fail "[$m] Conversion failed - output GGUF not found"
    fi

    info "[$m] Cleaning up safetensors source dir ($src_dir)..."
    rm -rf "$src_dir"

    ok "[$m] Converted: $model_dir/$name"
    echo ""
}

section_models() {
    info "=== Section 3: Download Models ==="

    if [[ $UPDATE_MODE -eq 1 ]]; then
        ok "Update mode: skipping model downloads"
        return
    fi

    local m="$MODEL"
    local repo="${MODEL_HF_REPO[$m]}"
    local name="${MODEL_NAME[$m]}"
    local dir_name="${MODEL_DIR_NAME[$m]}"
    local mmproj="${MODEL_MMPROJ[$m]}"
    local model_dir="$MODELS_DIR/$dir_name"

    if [[ "${MODEL_SOURCE[$m]:-}" == "safetensors" ]]; then
        section_convert "$m"
        mmproj="${MODEL_MMPROJ[$m]}"
        if [[ -n "$mmproj" ]]; then
            local mmproj_repo="${MODEL_MMPROJ_REPO[$m]:-$repo}"
            local hf_token_args=()
            if [[ -n "$HF_TOKEN" ]]; then
                hf_token_args+=("--token" "$HF_TOKEN")
            fi
            if [[ -f "$model_dir/$mmproj" ]]; then
                ok "[$m] mmproj already exists. Skipping."
            else
                info "[$m] Downloading $mmproj from $mmproj_repo..."
                HF_XET_HIGH_PERFORMANCE=1 "$HF_CLI" download "$mmproj_repo" "$mmproj" --local-dir "$model_dir" "${hf_token_args[@]}"
            fi
        fi
        ok "[$m] Model files:"
        ls -lh "$model_dir/"
        echo ""
        return
    fi

    mkdir -p "$model_dir"

    local hf_token_args=()
    if [[ -n "$HF_TOKEN" ]]; then
        hf_token_args+=("--token" "$HF_TOKEN")
    fi

    if [[ -f "$model_dir/$name" ]]; then
        ok "[$m] Model already exists: $name. Skipping."
    else
        info "[$m] Downloading $name..."
        HF_XET_HIGH_PERFORMANCE=1 "$HF_CLI" download "$repo" "$name" --local-dir "$model_dir" "${hf_token_args[@]}"
    fi

    if [[ -n "$mmproj" ]]; then
        local mmproj_repo="${MODEL_MMPROJ_REPO[$m]:-$repo}"
        if [[ -f "$model_dir/$mmproj" ]]; then
            ok "[$m] mmproj already exists. Skipping."
        else
            info "[$m] Downloading $mmproj from $mmproj_repo..."
            HF_XET_HIGH_PERFORMANCE=1 "$HF_CLI" download "$mmproj_repo" "$mmproj" --local-dir "$model_dir" "${hf_token_args[@]}"
        fi
    fi

    ok "[$m] Model files:"
    ls -lh "$model_dir/"
    echo ""
}

# ─── Main ────────────────────────────────────────────────────────
main() {
    echo "╔══════════════════════════════════════════════════════════════════════╗"
    echo "║  User-Space MTP Setup — builds to ~/.local (no sudo)               ║"
    echo "║  Target: $LLAMA_DIR                          ║"
    echo "╚══════════════════════════════════════════════════════════════════════╝"
    echo ""

    info "Setting up model: $MODEL"
    echo ""

    section_prerequisites
    section_build
    section_models

    local alias_list="${MODEL_DIR_NAME[$MODEL]}"
    # Show the short alias for this model
    case "$MODEL" in
        qwen38)  alias_list="qwen38" ;;
        nvfp4)   alias_list="nvfp4" ;;
        qwopus)  alias_list="qwopus" ;;
        huihui)  alias_list="huihui" ;;
        *)       alias_list="$MODEL" ;;
    esac

    ok "═══════════════════════════════════════════════════════════"
    ok "Setup complete! All user-space, no sudo needed."
    ok "═══════════════════════════════════════════════════════════"
    echo ""
    info "Start the model:"
    info "  ./scripts/switch-model.sh ${alias_list}"
    echo ""
    info "Check status:"
    info "  ./scripts/switch-model.sh status"
    echo ""
}

main "$@"
