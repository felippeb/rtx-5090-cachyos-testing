# Meetily Build Notes - CachyOS + RTX 5090

## System Environment
- **OS**: CachyOS Linux (Arch-based)
- **GPU**: NVIDIA GeForce RTX 5090 (Compute Capability 12.0)
- **Display Server**: Wayland
- **Privileges**: No sudo access (except journalctl)

## Key Issues & Solutions

### 1. CUDA Architecture for RTX 5090
**Problem**: Meetily hardcodes `CMAKE_CUDA_ARCHITECTURES='75'` (RTX 3080), incompatible with RTX 5090 (compute cap 12.0).

**Solution**: Modified `frontend/scripts/tauri-auto.js` line 45:
```bash
# Before:
-e CMAKE_CUDA_ARCHITECTURES='75' \

# After:
-e "CMAKE_CUDA_ARCHITECTURES=${MEETILI_CUDA_ARCH:-120}" \
```
Now pass `MEETILI_CUDA_ARCH=120` or any target architecture.

### 2. whisper-rs Compatibility
**Problem**: `whisper-rs` 0.13.2 fails to build with bindgen generating opaque structs:
```text
error[E0603]: module macro `crate` is private
error[E0609]: no field `general_system_prompt` on type `&mut whisper_full_params`
```

**Solution**: Upgraded to `whisper-rs` 0.16.0 in `Cargo.toml` (lines 57, 83, 114):
```toml
# Before:
whisper-rs = { version = "0.13.2", ... }

# After:
whisper-rs = { version = "0.16.0", ... }
```

**API Changes Required**:
- `set_suppress_non_speech_tokens()` → `set_suppress_nst()` (line 597)
- `full_get_segment_text_lossy(i)` → `get_segment(i).and_then(|s| s.to_str_lossy().ok())` (lines 743, 753-759)
- Removed `?` from `full_n_segments()` calls (line 673)

### 3. Tauri 2.x Macro Compatibility
**Problem**: Missing `__tauri_command_name_*` functions cause linker errors:
```text
undefined reference to `__tauri_command_name_transcribe'
undefined reference to `__tauri_command_name_builtin_ai_summarize'
```

**Solution**: Added re-exports in module files:
- `src/summary/mod.rs`: Added `pub use crate::commands::summary::__tauri_command_name_*;`
- `src/summary/summary_engine/mod.rs`: Added `pub use crate::commands::summary::__tauri_command_name_builtin_ai_*;`

### 4. Wayland Rendering Issues
**Problem**: App crashes with "Gdk-Message: Error 71 (Protocol error) dispatching to Wayland display" and shows grey box.

**Solution**: Force X11 backend via environment variable:
```bash
export GDK_BACKEND=x11
```
Include in launcher script: `~/.local/bin/meetily`

## Build Commands
```bash
# Set CUDA arch for RTX 5090
export MEETILI_CUDA_ARCH=120

# Build with CUDA (uses modified tauri-auto.js)
cargo tauri build --config tauri.cuda.conf.json

# Or run directly
cargo tauri dev --config tauri.cuda.conf.json
```

## Runtime Environment Variables
```bash
export GDK_BACKEND=x11                    # Fix Wayland rendering
export MEETILI_CUDA_ARCH=120             # CUDA architecture (optional, 120 is default)
```

## Setup Script
See `scripts/setup-meetily.sh` for automated setup on similar systems.

## Performance Notes
- RTX 5090 shows ~93% GPU utilization during model loading
- Models download at ~75MB/s
- App uses ~2GB RAM when idle, ~6.4% system memory under load
- CUDA acceleration confirmed working: "NVIDIA CUDA support: enabled"

## Model Files
Models are stored in `~/.local/share/meetily/models/` (created on first run):
- Parakeet-ASR-large (transcription): ~640MB
- gemma3:1b (summarization): ~1GB

## Next Steps for Testing
1. Wait for model downloads to complete
2. Test transcription with a sample audio file or live meeting
3. Verify CUDA acceleration is active during inference
4. Test summarization features
