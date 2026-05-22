#!/usr/bin/env bash
# Unified MTP setup script for llama.cpp on CachyOS + RTX 5090
# Builds llama.cpp from mainline (ggml-org) with MTP PR #22673
# Supports: Qwen3.6-27B MTP, Qwen3.6-35B-A3B MTP
#
# Usage: sudo bash setup-mtp.sh --model <27b|35b|nvfp4|35b-mxfp4|35b-nvfp4> [--update] [--test] [--hf-token TOKEN]
#        sudo bash setup-mtp.sh --all [--update] [--hf-token TOKEN]
#
# --model 27b         Set up Qwen3.6-27B MTP (dense, ~11GB, Q4_K_XL GGUF)
# --model 35b         Set up Qwen3.6-35B-A3B MTP (MoE, ~23GB, Q4_K_XL GGUF)
# --model nvfp4       Set up Qwen3.6-27B NVFP4-MTP (~20GB, NVFP4 GGUF, Blackwell-optimized)
# --model 35b-mxfp4   Set up Qwen3.6-35B-A3B MXFP4-MTP (~22GB, Blackwell FP4 + MTP spec decode)
# --model 35b-nvfp4   Set up Qwen3.6-35B-A3B NVFP4 (~21GB, Blackwell FP4, no MTP in GGUF)
# --all          Set up all models
# --update       Rebuild llama.cpp only, skip model downloads
# --test         Install to /opt/llama-mtp-test/ on port 10502
# --hf-token     Pass HuggingFace token through sudo (needed for gated repos)

set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────
MODEL=""
UPDATE_MODE=0
TEST_MODE=0
ALL_MODE=0
HF_TOKEN=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --model)
            [[ $# -ge 2 ]] || { echo "Missing value for --model" >&2; exit 1; }
            MODEL="$2"; shift 2 ;;
        --all)      ALL_MODE=1; shift ;;
        --update)   UPDATE_MODE=1; shift ;;
        --test)     TEST_MODE=1; shift ;;
        --hf-token)
            [[ $# -ge 2 ]] || { echo "Missing value for --hf-token" >&2; exit 1; }
            HF_TOKEN="$2"; shift 2 ;;
        *)
            echo "Unknown argument: $1" >&2
            echo "Usage: sudo bash $0 --model <27b|35b|nvfp4|35b-mxfp4|35b-nvfp4> [--update] [--test] [--hf-token TOKEN]"
            echo "       sudo bash $0 --all [--update] [--hf-token TOKEN]"
            exit 1 ;;
    esac
done

if [[ $ALL_MODE -eq 1 ]]; then
    MODEL="all"
fi

if [[ -z "$MODEL" ]]; then
    echo "Error: --model is required (27b, 35b, nvfp4, 35b-mxfp4, or 35b-nvfp4)" >&2
    echo "Usage: sudo bash $0 --model <27b|35b|nvfp4|35b-mxfp4|35b-nvfp4> [--update] [--test]"
    exit 1
fi

if [[ $TEST_MODE -eq 1 ]]; then
    LLAMA_DIR="/opt/llama-mtp-test"
    MODELS_DIR="/opt/models-mtp-test"
    SERVICE_NAME_SUFFIX="-test"
    SERVER_PORT=10502
else
    LLAMA_DIR="/opt/llama-mtp"
    MODELS_DIR="/opt/models-mtp"
    SERVICE_NAME_SUFFIX=""
    SERVER_PORT=10500
fi

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

# ─── Model definitions ──────────────────────────────────────────
declare -A MODEL_HF_REPO MODEL_NAME MODEL_DIR_NAME MODEL_MMPROJ MODEL_MMPROJ_REPO

MODEL_HF_REPO[27b]="unsloth/Qwen3.6-27B-MTP-GGUF"
MODEL_NAME[27b]="Qwen3.6-27B-UD-Q4_K_XL.gguf"
MODEL_DIR_NAME[27b]="qwen3.6-27b-mtp"
MODEL_MMPROJ[27b]="mmproj-F16.gguf"

MODEL_HF_REPO[35b]="havenoammo/Qwen3.6-35B-A3B-MTP-GGUF"
MODEL_NAME[35b]="Qwen3.6-35B-A3B-MTP-UD-Q4_K_XL.gguf"
MODEL_DIR_NAME[35b]="qwen3.6-35b-a3b-mtp"
MODEL_MMPROJ[35b]=""

MODEL_HF_REPO[nvfp4]="nilayparikh/Qwen3.6-27B-Text-NVFP4-MTP-GGUF"
MODEL_NAME[nvfp4]="qwen3.6-27b-text-nvfp4-mtp.gguf"
MODEL_DIR_NAME[nvfp4]="qwen3.6-27b-nvfp4-mtp"
MODEL_MMPROJ[nvfp4]="mmproj-F16.gguf"
MODEL_MMPROJ_REPO[nvfp4]="unsloth/Qwen3.6-27B-MTP-GGUF"

# 35B-A3B MXFP4-MTP (Blackwell FP4 + MTP, unsloth)
MODEL_HF_REPO[35b-mxfp4]="unsloth/Qwen3.6-35B-A3B-MTP-GGUF"
MODEL_NAME[35b-mxfp4]="Qwen3.6-35B-A3B-MXFP4_MOE.gguf"
MODEL_DIR_NAME[35b-mxfp4]="qwen3.6-35b-a3b-mxfp4-mtp"
MODEL_MMPROJ[35b-mxfp4]="mmproj-F16.gguf"

# 35B-A3B NVFP4 (Blackwell FP4, no MTP in GGUF, knoopx)
MODEL_HF_REPO[35b-nvfp4]="knoopx/Qwen3.6-35B-A3B-NVFP4-GGUF"
MODEL_NAME[35b-nvfp4]="Qwen3.6-35B-A3B-NVFP4.gguf"
MODEL_DIR_NAME[35b-nvfp4]="qwen3.6-35b-a3b-nvfp4"
MODEL_MMPROJ[35b-nvfp4]="mmproj-BF16.gguf"

get_models_to_setup() {
    if [[ "$MODEL" == "all" ]]; then
        echo "27b 35b nvfp4 35b-mxfp4 35b-nvfp4"
    else
        echo "$MODEL"
    fi
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
    pacman -S --needed --noconfirm base-devel cmake git uv gcc14 aria2

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
}

# ─── Section 2: Build llama.cpp with MTP PR ─────────────────────
section_build() {
    info "=== Section 2: Build llama.cpp (mainline + MTP PR #$PR_NUM) ==="

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

    local WORK_DIR="$LLAMA_DIR"
    local NEEDS_CLONE=false

    if [[ -d "$LLAMA_DIR" ]] && [[ -d "$LLAMA_DIR/.git" ]]; then
        if [[ $UPDATE_MODE -eq 1 ]]; then
            ok "Update mode: will pull latest in $LLAMA_DIR"
        elif has_mtp "$LLAMA_DIR/build/bin/llama-server"; then
            ok "MTP already supported in existing build at $LLAMA_DIR"
            return
        else
            warn "Existing build lacks MTP. Cloning fresh."
            WORK_DIR="/tmp/llama-mtp-build"
            NEEDS_CLONE=true
        fi
    elif [[ ! -d "$LLAMA_DIR" ]]; then
        NEEDS_CLONE=true
        WORK_DIR="/tmp/llama-mtp-build"
    fi

    if [[ "$NEEDS_CLONE" == true ]]; then
        rm -rf "$WORK_DIR"
        info "Cloning llama.cpp (ggml-org, full history for merge)..."
        git clone "$LLAMA_REPO" "$WORK_DIR"
    fi

    pushd "$WORK_DIR" >/dev/null

    # Abort any in-progress merge from a previous failed run
    git merge --abort 2>/dev/null || true

    info "Fetching latest..."
    git fetch origin

    info "Checking out master..."
    git checkout master 2>/dev/null || git checkout -b master origin/master
    git reset --hard origin/master

    # Check if MTP is already in mainline (PR #22673 merged upstream)
    if grep -rq "draft.mtp\|DRAFT_MTP\|spec_type.*mtp" "$WORK_DIR/src/" "$WORK_DIR/common/" 2>/dev/null; then
        ok "MTP support already in mainline. Skipping PR merge."
    else
        info "MTP not in current build. Fetching PR #$PR_NUM..."
        git fetch origin "pull/$PR_NUM/head:pr-$PR_NUM" || true

        # Use sudo user's identity for merge commit (running as root)
        local git_user
        git_user=$(getent passwd "${SUDO_USER:-root}" | cut -d: -f5 | cut -d, -f1)
        git_user="${git_user:-$SUDO_USER}"
        export GIT_AUTHOR_NAME="$git_user"
        export GIT_AUTHOR_EMAIL="${SUDO_USER:-root}@$(hostname -f 2>/dev/null || hostname)"
        export GIT_COMMITTER_NAME="$git_user"
        export GIT_COMMITTER_EMAIL="${SUDO_USER:-root}@$(hostname -f 2>/dev/null || hostname)"

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

    # Clear stale CMake cache if source directory changed
    if [[ -f "$WORK_DIR/build/CMakeCache.txt" ]]; then
        local cached_src
        cached_src=$(grep "CMAKE_HOME_DIRECTORY" "$WORK_DIR/build/CMakeCache.txt" 2>/dev/null | cut -d= -f2 || true)
        if [[ -n "$cached_src" ]] && [[ "$cached_src" != "$WORK_DIR" ]]; then
            info "Stale CMake cache from $cached_src. Clearing..."
            rm -f "$WORK_DIR/build/CMakeCache.txt"
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

    if [[ "$WORK_DIR" != "$LLAMA_DIR" ]]; then
        info "Moving build to $LLAMA_DIR..."
        popd >/dev/null
        rm -rf "$LLAMA_DIR"
        mv "$WORK_DIR" "$LLAMA_DIR"
    else
        popd >/dev/null
    fi

    ok "MTP-enabled llama-server installed at $binary"

    info "Verifying MTP support..."
    if has_mtp "$LLAMA_DIR/build/bin/llama-server"; then
        ok "MTP support confirmed (--spec-type available)"
    else
        fail "MTP support NOT detected. Check: LD_LIBRARY_PATH=$LLAMA_DIR/build/bin $binary --help | grep spec-type"
    fi

    # Copy chat template (froggeric/Qwen-Fixed-Chat-Templates)
    local SCRIPT_DIR
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    if [[ -f "$SCRIPT_DIR/chat_template.jinja" ]]; then
        cp "$SCRIPT_DIR/chat_template.jinja" "$LLAMA_DIR/chat_template.jinja"
        ok "Copied chat_template.jinja to $LLAMA_DIR/"
    fi

    echo ""
}

# ─── Section 3: Download Models ─────────────────────────────────
section_models() {
    info "=== Section 3: Download Models ==="

    if [[ $UPDATE_MODE -eq 1 ]]; then
        ok "Update mode: skipping model downloads"
        return
    fi

    for m in $(get_models_to_setup); do
        local repo="${MODEL_HF_REPO[$m]}"
        local name="${MODEL_NAME[$m]}"
        local dir_name="${MODEL_DIR_NAME[$m]}"
        local mmproj="${MODEL_MMPROJ[$m]}"
        local model_dir="$MODELS_DIR/$dir_name"

        mkdir -p "$model_dir"

        local hf_args=()
        if [[ -n "$HF_TOKEN" ]]; then
            hf_args+=("--token" "$HF_TOKEN")
        fi

        if [[ -f "$model_dir/$name" ]]; then
            ok "[$m] Model already exists: $name. Skipping."
        else
            info "[$m] Downloading $name..."
            HF_XET_HIGH_PERFORMANCE=1 "$HF_CLI" download "$repo" "$name" --local-dir "$model_dir" "${hf_args[@]}"
        fi

        if [[ -n "$mmproj" ]]; then
            local mmproj_repo="${MODEL_MMPROJ_REPO[$m]:-$repo}"
            if [[ -f "$model_dir/$mmproj" ]]; then
                ok "[$m] mmproj already exists. Skipping."
            else
                info "[$m] Downloading $mmproj from $mmproj_repo..."
                HF_XET_HIGH_PERFORMANCE=1 "$HF_CLI" download "$mmproj_repo" "$mmproj" --local-dir "$model_dir" "${hf_args[@]}"
            fi
        fi

        ok "[$m] Model files:"
        ls -lh "$model_dir/"
        echo ""
    done
}

# ─── Section 4: Systemd Services ────────────────────────────────
section_services() {
    info "=== Section 4: Install systemd services ==="

    local SCRIPT_DIR
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    local CONFIGS_DIR="$SCRIPT_DIR/services"

    info "Enabling nvidia-persistenced..."
    systemctl enable --now nvidia-persistenced || warn "nvidia-persistenced may already be running"

    # Install service files with path substitution
    local svc_list=()
    for m in $(get_models_to_setup); do
        case "$m" in
            27b|35b)     svc_list+=("llama-server-mtp" "llama-server-mtp-131k") ;;
            nvfp4)       svc_list+=("llama-server-nvfp4-mtp" "llama-server-nvfp4-mtp-131k" "llama-server-nvfp4-mtp-262k") ;;
            35b-mxfp4)   svc_list+=("llama-server-35b-mxfp4-mtp" "llama-server-35b-mxfp4-mtp-131k") ;;
            35b-nvfp4)   svc_list+=("llama-server-35b-nvfp4" "llama-server-35b-nvfp4-131k") ;;
        esac
    done
    # Deduplicate
    local unique_svcs=()
    for s in "${svc_list[@]}"; do
        local found=0
        for u in "${unique_svcs[@]+"${unique_svcs[@]}"}"; do
            [[ "$s" == "$u" ]] && found=1 && break
        done
        [[ $found -eq 0 ]] && unique_svcs+=("$s")
    done
    for svc_base in "${unique_svcs[@]}"; do
        local src="$CONFIGS_DIR/${svc_base}.service"
        local dest_name="${svc_base}${SERVICE_NAME_SUFFIX}.service"
        if [[ -f "$src" ]]; then
            sed -e "s|__USERNAME__|${SUDO_USER:-root}|g" \
                -e "s|/opt/llama-mtp|$LLAMA_DIR|g" \
                -e "s|/opt/models-mtp|$MODELS_DIR|g" \
                -e "s|--port 10500|--port $SERVER_PORT|g" \
                "$src" > "/etc/systemd/system/$dest_name"
            ok "Installed /etc/systemd/system/$dest_name"
        else
            warn "Service file not found: $src"
        fi
    done

    systemctl daemon-reload

    # Pick the right default service and switcher shortcuts based on model
    local default_svc switcher_64k switcher_131k
    case "$MODEL" in
        nvfp4)
            default_svc="llama-server-nvfp4-mtp${SERVICE_NAME_SUFFIX}"
            switcher_64k="nvfp4-mtp-llama"
            switcher_131k="nvfp4-mtp-llama-131k"
            ;;
        35b-mxfp4)
            default_svc="llama-server-35b-mxfp4-mtp${SERVICE_NAME_SUFFIX}"
            switcher_64k="35b-mxfp4-mtp"
            switcher_131k="35b-mxfp4-mtp-131k"
            ;;
        35b-nvfp4)
            default_svc="llama-server-35b-nvfp4${SERVICE_NAME_SUFFIX}"
            switcher_64k="35b-nvfp4"
            switcher_131k="35b-nvfp4-131k"
            ;;
        *)
            default_svc="llama-server-mtp${SERVICE_NAME_SUFFIX}"
            switcher_64k="mtp"
            switcher_131k="mtp-131k"
            ;;
    esac

    info "Starting server on port $SERVER_PORT..."
    systemctl enable --now "$default_svc"

    sleep 3
    if systemctl is-active --quiet "$default_svc"; then
        ok "$default_svc is running on port $SERVER_PORT"
    else
        warn "Service failed to start. Check: journalctl -u $default_svc -n 30 --no-pager"
    fi

    echo ""
    info "To switch between 64K and 131K context:"
    info "  ./scripts/service-switcher.sh $switcher_64k         (64K)"
    info "  ./scripts/service-switcher.sh $switcher_131k    (131K)"
    info "  ./scripts/service-switcher.sh stop        (stop)"
    echo ""
}

# ─── Main ────────────────────────────────────────────────────────
main() {
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║  Unified MTP Setup — llama.cpp (mainline + PR #22673)   ║"
    if [[ $TEST_MODE -eq 1 ]]; then
        echo "║  Target: $LLAMA_DIR  Port: $SERVER_PORT                 ║"
    else
        echo "║  Target: $LLAMA_DIR                                     ║"
    fi
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""

    if [[ "$MODEL" == "all" ]]; then
        info "Setting up all models: 27b, 35b, nvfp4"
    else
        info "Setting up model: $MODEL"
    fi
    echo ""

    section_prerequisites
    section_build
    section_models
    section_services

    ok "═══════════════════════════════════════════════════════════"
    ok "Setup complete!"
    ok "═══════════════════════════════════════════════════════════"
    echo ""
    info "Next steps:"
    info "  1. Verify:  curl http://localhost:$SERVER_PORT/v1/models"
    info "  2. Bench:   ./benchmarks/run-tool-bench.sh"
    info "  3. Use:     opencode"
    echo ""
}

main "$@"
