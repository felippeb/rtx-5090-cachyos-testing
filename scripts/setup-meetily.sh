#!/usr/bin/env bash
# Setup script for Meetily (AI Meeting Assistant) on CachyOS + RTX 5090
# Installs to ~/repos/meetily with CUDA acceleration
# Run as: bash setup-meetily.sh [--update|--clean|--dev]
#
# --update  Rebuild without re-cloning (preserves models/config)
# --clean   Fresh install (removes existing build artifacts)
# --dev     Development mode with hot reload

set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────
UPDATE_MODE=0
CLEAN_MODE=0
DEV_MODE=0
for arg in "$@"; do
    case "$arg" in
        --update) UPDATE_MODE=1 ;;
        --clean)  CLEAN_MODE=1 ;;
        --dev)    DEV_MODE=1 ;;
    esac
done

MEETILY_DIR="$HOME/repos/meetily"
FRONTEND_DIR="$MEETILY_DIR/frontend"
TAURI_DIR="$MEETILY_DIR/frontend/src-tauri"
LLAMA_HELPER_DIR="$MEETILY_DIR/llama-helper"
MODELS_DIR="$HOME/.local/share/com.meetily.ai/models"
REPO_URL="https://github.com/Zackriya-Solutions/meetily.git"

# RTX 5090 Blackwell configuration
GPU_ARCH="120"  # sm_120 for RTX 5090 (compute capability 12.0)
CUDA_STANDARD="17"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail()  { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }
header(){ echo -e "\n${BOLD}${CYAN}========================================${NC}"; echo -e "${BOLD}${CYAN} $*${NC}"; echo -e "${BOLD}${CYAN}========================================${NC}\n"; }

# ─── Section 1: Prerequisites ───────────────────────────────────
section_prerequisites() {
    header "Section 1: Prerequisites"

    # Check GPU
    info "Checking NVIDIA GPU..."
    if ! command -v nvidia-smi &>/dev/null; then
        fail "nvidia-smi not found. Install NVIDIA drivers first."
    fi
    local gpu_name
    gpu_name=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1 | xargs)
    ok "GPU: $gpu_name"

    local compute_cap
    compute_cap=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader | head -1 | xargs | tr -d '.')
    info "Compute capability: ${compute_cap#0} (configured: $GPU_ARCH)"
    if [[ "$compute_cap" != "120" ]]; then
        warn "GPU compute cap ($compute_cap) differs from RTX 5090 expected (120). Adjust GPU_ARCH if needed."
    fi

    # Check CUDA toolkit
    info "Checking CUDA toolkit..."
    if ! command -v nvcc &>/dev/null; then
        fail "nvcc not found. Install CUDA toolkit: sudo pacman -S cuda"
    fi
    local cuda_ver
    cuda_ver=$(nvcc --version | grep "release" | awk '{print $5}' | tr -d ',')
    ok "CUDA: $cuda_ver"

    # Check system dependencies (CachyOS/Arch)
    info "Checking system dependencies..."
    local missing_deps=()
    for dep in cmake git python; do
        if ! command -v "$dep" &>/dev/null; then
            missing_deps+=("$dep")
        fi
    done
    # Node.js is 'node' on Arch/CachyOS, 'nodejs' on Debian/Ubuntu
    if ! command -v node &>/dev/null && ! command -v nodejs &>/dev/null; then
        missing_deps+=("nodejs")
    fi

    # Check Arch-specific packages
    for pkg in webkit2gtk-4.1 gtk3 alsa-lib libpulse; do
        if ! pacman -Q "$pkg" &>/dev/null 2>&1; then
            missing_deps+=("$pkg")
        fi
    done

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        warn "Missing dependencies: ${missing_deps[*]}"
        info "Install with: sudo pacman -S ${missing_deps[*]}"
        fail "Install missing dependencies and retry."
    fi
    ok "All system dependencies satisfied"

    # Check/install Rust (user-level)
    info "Checking Rust toolchain..."
    if ! command -v rustc &>/dev/null && [[ ! -f "$HOME/.cargo/env" ]]; then
        warn "Rust not found. Installing via rustup..."
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
        source "$HOME/.cargo/env"
        ok "Rust installed"
    fi
    source "$HOME/.cargo/env" 2>/dev/null || true
    local rust_ver
    rust_ver=$(rustc --version | awk '{print $2}')
    ok "Rust: $rust_ver"

    # Check/install pnpm/npm
    info "Checking package manager..."
    if ! command -v npm &>/dev/null; then
        fail "npm not found. Install Node.js first."
    fi
    local npm_ver
    npm_ver=$(npm --version)
    ok "npm: $npm_ver"
}

# ─── Section 2: Repository Setup ────────────────────────────────
section_repo() {
    header "Section 2: Repository Setup"

    if [[ $UPDATE_MODE -eq 1 ]]; then
        info "Update mode: skipping clone, pulling latest changes..."
        cd "$MEETILY_DIR"
        git pull || warn "Git pull failed (may be clean already)"
        git submodule update --init --recursive || warn "Submodule update failed"
        return 0
    fi

    if [[ -d "$MEETILY_DIR" ]]; then
        if [[ $CLEAN_MODE -eq 1 ]]; then
            info "Clean mode: removing existing installation..."
            rm -rf "$MEETILY_DIR"
        else
            warn "Meetily already exists at $MEETILY_DIR"
            read -p "Remove and reinstall? (y/N) " -n 1 -r
            echo
            if [[ $_ =~ ^[Yy]$ ]]; then
                rm -rf "$MEETILY_DIR"
            else
                info "Reusing existing installation"
                cd "$MEETILY_DIR"
                git submodule update --init --recursive
                return 0
            fi
        fi
    fi

    # Clone repository
    info "Cloning Meetily repository..."
    mkdir -p "$HOME/repos"
    git clone "$REPO_URL" "$MEETILY_DIR" || fail "Failed to clone repository"
    ok "Repository cloned to $MEETILY_DIR"

    # Initialize submodules
    info "Initializing git submodules..."
    cd "$MEETILY_DIR"
    git submodule update --init --recursive || warn "Submodule initialization had issues"
}

# ─── Section 3: Apply Compatibility Patches ─────────────────────
section_patches() {
    header "Section 3: Apply Compatibility Patches"

    # Patch 1: CUDA architecture for RTX 5090
    info "Patching CUDA architecture for RTX 5090..."
    local tauri_auto="$FRONTEND_DIR/scripts/tauri-auto.js"
    if grep -q "CMAKE_CUDA_ARCHITECTURES = '75'" "$tauri_auto" 2>/dev/null; then
        sed -i "s/CMAKE_CUDA_ARCHITECTURES = '75'/CMAKE_CUDA_ARCHITECTURES = process.env.CMAKE_CUDA_ARCHITECTURES || '$GPU_ARCH'/" "$tauri_auto"
        ok "Applied: CUDA arch configurable (default: $GPU_ARCH)"
    else
        ok "Already patched or not needed"
    fi

    # Patch 2: whisper-rs upgrade to 0.16.0 (fixes bindgen issues)
    info "Checking whisper-rs version..."
    local cargo_toml="$TAURI_DIR/Cargo.toml"
    if grep -q 'whisper-rs.*0.13.2' "$cargo_toml" 2>/dev/null; then
        sed -i 's/whisper-rs = { version = "0.13.2"/whisper-rs = { version = "0.16.0"/g' "$cargo_toml"
        ok "Applied: whisper-rs upgraded to 0.16.0"
    else
        ok "Already at correct version or not needed"
    fi

    # Patch 3: whisper-rs 0.16.0 API adaptations
    info "Applying whisper-rs 0.16.0 API patches..."
    local whisper_engine="$TAURI_DIR/src/whisper_engine/whisper_engine.rs"

    if grep -q 'set_suppress_non_speech_tokens' "$whisper_engine" 2>/dev/null; then
        sed -i 's/set_suppress_non_speech_tokens/set_suppress_nst/g' "$whisper_engine"
        ok "Applied: set_suppress_nst API update"
    fi

    if grep -q 'full_get_segment_text_lossy' "$whisper_engine" 2>/dev/null; then
        sed -i 's/match state.full_get_segment_text_lossy(i)/match state.get_segment(i).and_then(|s| s.to_str_lossy().ok())/g' "$whisper_engine"
        ok "Applied: get_segment API update"
    fi

    if grep -q 'full_n_segments()?' "$whisper_engine" 2>/dev/null; then
        sed -i 's/state.full_n_segments()?/state.full_n_segments()/g' "$whisper_engine"
        ok "Applied: full_n_segments no longer returns Result"
    fi

    if grep -q 'full_get_segment_t0' "$whisper_engine" 2>/dev/null; then
        sed -i 's/state.full_get_segment_t0(i).unwrap_or(0)/state.get_segment(i).map(|s| s.t0).unwrap_or(0)/g' "$whisper_engine"
        sed -i 's/state.full_get_segment_t1(i).unwrap_or(0)/state.get_segment(i).map(|s| s.t1).unwrap_or(0)/g' "$whisper_engine"
        ok "Applied: segment timing API update"
    fi

    if grep -q '&model_info.path.to_string_lossy()' "$whisper_engine" 2>/dev/null; then
        sed -i 's/&model_info.path.to_string_lossy()/\&*model_info.path.to_string_lossy()/g' "$whisper_engine"
        ok "Applied: path conversion fix"
    fi

    # Patch 4: Tauri command name exports (Tauri 2.x compatibility)
    info "Checking Tauri command exports..."
    local summary_mod="$TAURI_DIR/src/summary/mod.rs"
    if ! grep -q '__tauri_command_name_api_process_transcript' "$summary_mod" 2>/dev/null; then
        # Apply patch via Python for complex multi-line changes
        python3 - "$summary_mod" <<'PYEOF'
import sys, re

with open(sys.argv[1], 'r') as f:
    content = f.read()

# Patch summary/mod.rs
old_reexport = '''pub use commands::{
    __cmd__api_cancel_summary, __cmd__api_get_summary, __cmd__api_process_transcript,
    __cmd__api_save_meeting_summary, api_cancel_summary, api_get_summary,
    api_process_transcript, api_save_meeting_summary,
};'''

new_reexport = '''pub use commands::{
    __cmd__api_cancel_summary, __cmd__api_get_summary, __cmd__api_process_transcript,
    __cmd__api_save_meeting_summary, __tauri_command_name_api_cancel_summary,
    __tauri_command_name_api_get_summary, __tauri_command_name_api_process_transcript,
    __tauri_command_name_api_save_meeting_summary, api_cancel_summary, api_get_summary,
    api_process_transcript, api_save_meeting_summary,
};'''

content = content.replace(old_reexport, new_reexport)

old_template = '''pub use template_commands::{
    __cmd__api_get_template_details, __cmd__api_list_templates, __cmd__api_validate_template,
    api_get_template_details, api_list_templates, api_validate_template,
};'''

new_template = '''pub use template_commands::{
    __cmd__api_get_template_details, __cmd__api_list_templates, __cmd__api_validate_template,
    __tauri_command_name_api_get_template_details, __tauri_command_name_api_list_templates,
    __tauri_command_name_api_validate_template, api_get_template_details, api_list_templates,
    api_validate_template,
};'''

content = content.replace(old_template, new_template)

with open(sys.argv[1], 'w') as f:
    f.write(content)
PYEOF
        ok "Applied: Tauri command name exports"
    else
        ok "Already patched"
    fi

    # Patch 5: Sync Tauri plugin versions (prevent npm/Rust mismatch)
    info "Syncing Tauri plugin versions..."
    local cargo_toml="$TAURI_DIR/Cargo.toml"
    if grep -q 'tauri-plugin-fs = "2.4.0"' "$cargo_toml" 2>/dev/null; then
        sed -i 's/tauri-plugin-fs = "2.4.0"/tauri-plugin-fs = "=2.4.5"/' "$cargo_toml"
        cd "$TAURI_DIR" && cargo update -p tauri-plugin-fs 2>/dev/null || warn "Cargo update had issues"
        ok "Applied: Tauri fs plugin version synced"
    else
        ok "Already synced or not needed"
    fi

    # Patch 6: summary_engine module exports
    local engine_mod="$TAURI_DIR/src/summary/summary_engine/mod.rs"
    if ! grep -q '__tauri_command_name_builtin_ai_list_models' "$engine_mod" 2>/dev/null; then
        python3 - "$engine_mod" <<'PYEOF'
import sys

with open(sys.argv[1], 'r') as f:
    content = f.read()

old = '''pub use commands::{
    __cmd__builtin_ai_cancel_download, __cmd__builtin_ai_delete_model,
    __cmd__builtin_ai_download_model, __cmd__builtin_ai_get_available_summary_model,
    __cmd__builtin_ai_get_model_info, __cmd__builtin_ai_get_recommended_model, __cmd__builtin_ai_is_model_ready,
    __cmd__builtin_ai_list_models, builtin_ai_cancel_download, builtin_ai_delete_model, builtin_ai_download_model,
    builtin_ai_get_available_summary_model, builtin_ai_get_model_info, builtin_ai_get_recommended_model, builtin_ai_is_model_ready,
    builtin_ai_list_models, init_model_manager, ModelManagerState,
};'''

new = '''pub use commands::{
    __cmd__builtin_ai_cancel_download, __cmd__builtin_ai_delete_model,
    __cmd__builtin_ai_download_model, __cmd__builtin_ai_get_available_summary_model,
    __cmd__builtin_ai_get_model_info, __cmd__builtin_ai_get_recommended_model, __cmd__builtin_ai_is_model_ready,
    __cmd__builtin_ai_list_models,
    __tauri_command_name_builtin_ai_cancel_download, __tauri_command_name_builtin_ai_delete_model,
    __tauri_command_name_builtin_ai_download_model, __tauri_command_name_builtin_ai_get_available_summary_model,
    __tauri_command_name_builtin_ai_get_model_info, __tauri_command_name_builtin_ai_get_recommended_model,
    __tauri_command_name_builtin_ai_is_model_ready, __tauri_command_name_builtin_ai_list_models,
    builtin_ai_cancel_download, builtin_ai_delete_model, builtin_ai_download_model,
    builtin_ai_get_available_summary_model, builtin_ai_get_model_info, builtin_ai_get_recommended_model, builtin_ai_is_model_ready,
    builtin_ai_list_models, init_model_manager, ModelManagerState,
};'''

content = content.replace(old, new)

with open(sys.argv[1], 'w') as f:
    f.write(content)
PYEOF
        ok "Applied: summary_engine command exports"
    else
        ok "Already patched"
    fi
}

# ─── Section 4: Dependencies ────────────────────────────────────
section_dependencies() {
    header "Section 4: Install Dependencies"

    cd "$FRONTEND_DIR"

    # Update Cargo.lock for whisper-rs
    info "Updating Cargo.lock..."
    source "$HOME/.cargo/env"
    cargo update -p whisper-rs --precise 0.16.0 2>/dev/null || warn "Cargo update had issues (may be up to date)"

    # Install npm dependencies
    info "Installing frontend dependencies..."
    if [[ ! -d "node_modules" ]] || [[ $CLEAN_MODE -eq 1 ]]; then
        npm install --legacy-peer-deps 2>&1 | tail -5 || fail "Failed to install dependencies"
    fi
    ok "Frontend dependencies installed"
}

# ─── Section 5: Build ──────────────────────────────────────────
section_build() {
    header "Section 5: Build Meetily"

    cd "$MEETILY_DIR"
    source "$HOME/.cargo/env"

    # Build llama-helper sidecar with CUDA
    info "Building llama-helper sidecar with CUDA..."
    cd "$LLAMA_HELPER_DIR"
    cargo build --release --features cuda 2>&1 | tail -3
    ok "llama-helper built"

    # Copy binaries to expected locations
    local bin_dir="$TAURI_DIR/binaries"
    mkdir -p "$bin_dir"
    local target_triple
    target_triple=$(rustc -Vv | grep host | awk '{print $2}')

    cp "$MEETILY_DIR/target/release/llama-helper" "$bin_dir/llama-helper"
    cp "$bin_dir/llama-helper" "$bin_dir/llama-helper-$target_triple"
    ok "Binaries placed in $bin_dir"

    # Build Next.js frontend
    info "Building Next.js frontend..."
    cd "$FRONTEND_DIR"
    npm run build 2>&1 | tail -5 || fail "Frontend build failed"
    ok "Frontend built"

    # Build Tauri app with CUDA
    info "Building Tauri app with CUDA acceleration..."
    export CMAKE_CUDA_ARCHITECTURES="$GPU_ARCH"
    export CMAKE_CUDA_STANDARD="$CUDA_STANDARD"
    export CMAKE_CXX_STANDARD="$CUDA_STANDARD"
    export CMAKE_POSITION_INDEPENDENT_CODE=ON
    export NO_STRIP=true

    cd "$TAURI_DIR"
    # Temporarily bypass beforeBuildCommand since frontend is already built
    local orig_before_build
    orig_before_build=$(grep -o '"beforeBuildCommand": *"[^"]*"' "$TAURI_DIR/tauri.conf.json")
    sed -i 's/"beforeBuildCommand": *"pnpm build"/"beforeBuildCommand": "echo frontend-already-built"/' "$TAURI_DIR/tauri.conf.json"

    PATH="$FRONTEND_DIR/node_modules/.bin:$PATH" \
        node "$FRONTEND_DIR/node_modules/@tauri-apps/cli/tauri.js" build -- --features cuda 2>&1 | tail -10

    # Restore beforeBuildCommand
    sed -i "s/\"beforeBuildCommand\": *\"echo frontend-already-built\"/$orig_before_build/" "$TAURI_DIR/tauri.conf.json"

    ok "Tauri app built with CUDA!"
}

# ─── Section 6: Post-Install ────────────────────────────────────
section_postinstall() {
    header "Section 6: Setup Complete"

    local target_triple
    target_triple=$(rustc -Vv 2>/dev/null | grep host | awk '{print $2}')
    local binary="$MEETILY_DIR/target/release/meetily"
    local appimage="$MEETILY_DIR/target/release/bundle/appimage/meetily_*_amd64.AppImage"
    local deb="$MEETILY_DIR/target/release/bundle/deb/meetily_*_amd64.deb"

    echo ""
    ok "Meetily installed successfully!"
    echo ""
    info "📍 Installation: $MEETILY_DIR"
    info "🎯 GPU: $(nvidia-smi --query-gpu=name --format=csv,noheader | head -1 | xargs)"
    info "⚡ CUDA acceleration: ENABLED (arch: $GPU_ARCH)"
    info "📦 Models directory: $MODELS_DIR"
    echo ""
    info "Run the application (Wayland users: uses X11 backend):"
    echo "   ${BOLD}meetily${NC}"
    echo "   ${BOLD}(or: GDK_BACKEND=x11 $binary)${NC}"
    echo ""
    info "Or use the AppImage:"
    if ls $appimage 1>/dev/null 2>&1; then
        echo "   ${BOLD}. $(ls $appimage | head -1 | sed 's/^/\/\//')${NC}"
    fi
    echo ""
    info "Development mode (hot reload):"
    echo "   ${BOLD}cd $FRONTEND_DIR && CMAKE_CUDA_ARCHITECTURES=$GPU_ARCH PATH=\"node_modules/.bin:\$PATH\" node scripts/tauri-auto.js dev${NC}"
    echo ""

    # Create convenience launcher (workarounds for Wayland + WebKit rendering)
    local launcher="$HOME/.local/bin/meetily"
    mkdir -p "$HOME/.local/bin"
    cat > "$launcher" <<'EOF'
#!/usr/bin/env bash
# Meetily launcher - workarounds for Wayland + WebKit rendering
export GDK_BACKEND=x11
export WEBKIT_DISABLE_COMPOSITING_MODE=1
source "$HOME/.cargo/env" 2>/dev/null || true
exec "$HOME/repos/meetily/target/release/meetily" "$@"
EOF
    chmod +x "$launcher"
    ok "Created launcher: ~/.local/bin/meetily"
    info "(Add ~/.local/bin to PATH if not already there)"
}

# ─── Main ───────────────────────────────────────────────────────
main() {
    header "Meetily Setup for CachyOS + RTX 5090"
    info "AI Meeting Assistant with CUDA-accelerated transcription"
    echo ""

    section_prerequisites
    section_repo
    section_patches
    section_dependencies

    if [[ $DEV_MODE -eq 1 ]]; then
        header "Development Mode"
        info "Setup complete. Run dev mode with:"
        echo ""
        echo "${BOLD}cd $FRONTEND_DIR${NC}"
        echo "${BOLD}CMAKE_CUDA_ARCHITECTURES=$GPU_ARCH PATH=\"node_modules/.bin:\$PATH\" node scripts/tauri-auto.js dev${NC}"
        echo ""
        return 0
    fi

    section_build
    section_postinstall
}

main "$@"
