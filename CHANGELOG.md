# Changelog

All notable changes to this repository will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- Declarative model registry (`config/models.yaml`) with aliases and context safety tiers
- `benchmarks/kv-cache-bf16-vs-q8.md` — KV cache A/B (3 runs/leg): q8_0 consistently matches/beats bf16 (100×3 vs 93×3); bf16 OOMs above ~160K context
- `scripts/diagnose.sh` — runtime diagnostics (GPU, driver, services, template hash)
- `scripts/build-manifest.sh` — reproducibility manifest (git, system, GPU metadata)
- HuggingFace CLI venv at `~/.local/share/rtx-testing/.venv-hf/` (user-space, no sudo)

### Changed
- **BREAKING:** Migrate llama.cpp from `/opt/` to user-space (`~/.local/share/rtx-testing/llama.cpp-nvfp4/`)
- `llama/setup-mtp.sh` — rewritten for user-space: clones directly to final path, no `/tmp`, no sudo
- `scripts/switch-model.sh` — native model switcher replacing `service-switcher.sh`; reads model registry, handles HF downloads, legacy cleanup, GPU memory wait loop
- Build directory renamed from `llama-mtp` to `llama.cpp-nvfp4` for clarity
- Symlink at `~/.local/bin/llama-server` → user-space build binary
- Models install to `~/.local/share/rtx-testing/models/` (user-space)
- Chat template deploys to `~/.config/rtx-testing/chat_template.jinja`

### Fixed
- `LD_LIBRARY_PATH` silent CPU fallback — uses `readlink -f` to resolve symlink to real binary directory
- Stale systemd transient units — `clean_stale_units()` removes cached units before `systemd-run`
- `ensure_config()` searches multiple locations for `chat_template.jinja` (config/, llama/, models/)
- `stop_existing()` kills stray processes on port 10500, stops legacy system services, waits for GPU VRAM (20GB target, 60s timeout)

### Deprecated
- `scripts/service-switcher.sh` — replaced by `scripts/switch-model.sh`
- `/opt/llama-mtp/` and `/opt/models-mtp/` — replaced by user-space equivalents
- Legacy system-level systemd services (`llama-server-*`) — replaced by user units (`rtx-*`)

### Documentation
- Comprehensive README rewrite: user-space setup, model registry, context safety tiers, new architecture section
- Known issues table updated with symlink CPU fallback fix

## [2026-05-21]

### Changed
- Deprecate 64k/32k context services, keep only 131k+

### Fixed
- Add language tags to bare fenced code blocks
- Markdownlint config — disable line-length, bare urls, table style
- Shellcheck image tag v0.10.1 → v0.10.0
- Set sast/secret_detection to security stage
- Gitlab-ci.yml — remove duplicate sast/secret-detection job defs

### Documentation
- Comprehensive readme update — benchmarks, providers, services

### CI
- Add pre-commit hooks and gitlab ci pipeline

## [2026-05-20]

### Added
- Update 35b mxfp4-mtp benchmark with froggeric chat template
- Deploy froggeric chat template across all qwen services

### Changed
- Organize repo — benchmarks, docs, scripts into dedicated folders

### Fixed
- Update stale /opt/llama.cpp/ chat template paths to /opt/llama-mtp/

## [2026-05-19]

### Added
- Mark nvfp4-mtp models as vision-capable in opencode config
- Add vision support to nvfp4-mtp via unsloth mmproj
- Add nvfp4-mtp model support, consolidate services, add quantization tooling

### Fixed
- Add --mmproj to 35b mxfp4 and nvfp4 service files for vision

### Documentation
- Highlight nvfp4-mtp as daily driver, add full benchmark comparison

## [2026-05-18]

### Changed
- Unify mtp services, add chat templates, simplify tooling
- Remove 262k services, apply bf16 kv cache, update benchmarks

### Documentation
- Update readme for unified mtp setup, chat templates, new tooling

## [2026-05-17]

### Added
- Add all 3 mtp models to opencode.json and pi agent configs
- Add gemma 4 31b mtp services and setup script, update 35b-mtp memory limits

### Documentation
- Add qwen3.6-35b-a3b mtp benchmark results
- Update readme with full repo scan, clarify mtp vs non-mtp benchmarks

### Chore
- Cleanup repo, fix gitignore conflict, add new services and configs

### Merged
- Merge branch 'feat/repo-cleanup' into 'main'

## [2026-05-14]

### Added
- Add llama mtp/qwen model services, flux-server, vllm awq variants, service-switcher, and harden configs

### Fixed
- Resolve merge conflicts, update readme for qwen3.6-27b mtp as default, remove codex-desktop

### Chore
- Remove codex-desktop from repository

### Merged
- Merge branch 'feat/llama-flux-model-services' into 'main'
- Merge branch 'feat/codex-desktop-linux' into 'main'

## [2026-05-11]

### Added
- Add codex-desktop setup, vllm services, benchmark tool, and harden .gitignore

## [2026-05-08]

### Added
- Meetily cuda setup for rtx 5090 on cachyos (tested & reproducible)

### Merged
- Merge branch 'feat/meetily-cuda-rtx5090-v2' into 'main'
- Merge branch 'feat/meetily-cuda-rtx5090' into 'main'
- Merge branch 'feat/gemma4-robust-setup' into 'main'

### Reverted
- Revert "Update browser-harness: move to ~/.local/installs/, headless Brave systemd service"

### Other
- Update browser-harness: move to ~/.local/installs/, headless Brave systemd service
- Add browser-harness setup notes and troubleshooting guide
- Add browser-harness setup for LLM-controlled Brave

## [2026-05-07]

### Other
- Add Meetily setup script and build notes for RTX 5090/CachyOS

## [2026-05-05]

### Merged
- Merge branch 'feat/gemma4-robust-setup' into 'main'

### Other
- Add Qwen3.6-35B-A3B MoE model support
- Add gitleaks pre-commit hook (copy to .git/hooks/ to activate)
- Add opencode-mem persistent memory plugin setup with Bun sharp workaround

## [2026-05-04]

### Other
- Implement Gemma 4 support and harden setup scripts for RTX 5090 on CachyOS
- Separating out duckduckgo. adding gemma4

## [2026-04-30]

### Other
- Add presence_penalty and repeat-penalty to turbo service per Unsloth Qwen3.6-27B recommendations
- Add Nemotron-3-Nano-30B inference support and harden install/switcher scripts

## [2026-04-28]

### Other
- Convert llama services to user services with auto-restart and remove fan control
- Restructure repo by service and add Open WebUI web search
- Fix open-webui-docker.sh for host network mode and use default port 8080
- Disable autostart for all llama-server services
- Add reapply-services.sh helper to redeploy systemd configs from repo
- Add netdata dbengine config with 20GB tiered retention
- Add coolercontrol config and opencode.json

## [2026-04-27]

### Other
- Add VS Code extension support to free-claude-code setup
- Abstract user-specific paths in service files and install script
- Add free-claude-code install script and systemd service
- Adding other scripts
- Remove motherboard-specific reference from README
- Update README with setup.sh install instructions and /opt/ paths
- Configure Secret Detection in `.gitlab-ci.yml`, creating this file if it does not already exist
- Configure SAST in `.gitlab-ci.yml`, creating this file if it does not already exist
- Initial commit
