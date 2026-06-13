# RTX 5090 Local AI Setup (CachyOS)

Local AI coding environment on CachyOS with NVIDIA RTX 5090.

**Daily driver:** Qwen3.6-27B NVFP4-MTP (131K context) via llama.cpp mainline | NVFP4 GGUF | Best overall quality + speed (93/100, 1.2s median).

## Stack

| Component | Details |
| --- | --- |
| GPU | NVIDIA RTX 5090 (32GB GDDR7, Blackwell sm_120) |
| OS | CachyOS (Arch-based, KDE Plasma, Wayland) |
| Shell | fish |
| CUDA | 13.3 (driver 610.43.02) |
| Runtime | llama.cpp mainline (ggml-org) + MTP PR #22673 (NVFP4 native), vLLM |
| Default model | Qwen3.6-27B NVFP4-MTP (19.7 GB, 131K context, NVFP4 + speculative decoding) |
| Build location | `~/.local/share/rtx-testing/llama.cpp-nvfp4/` (user-space, no sudo) |
| UI | OpenCode, Claude Code (CLI + VS Code), Open WebUI |
| MCP tools | Context7 docs, Chrome DevTools, DuckDuckGo search, DesignMD |
| Package manager | pacman / paru |

## Quick Start

### User-Space Setup (Recommended)

```fish
# Fresh install — builds llama.cpp, downloads models, no sudo
bash llama/setup-mtp.sh --model nvfp4

# Rebuild only (keeps models)
bash llama/setup-mtp.sh --model nvfp4 --update
```

Builds llama.cpp from mainline (ggml-org) with MTP PR #22673. Installs to `~/.local/share/rtx-testing/llama.cpp-nvfp4/`, models to `~/.local/share/rtx-testing/models/`. Idempotent — re-runs skip what's installed.

### Switch Models (User-Space)

```fish
# ⭐ NVFP4-MTP (daily driver — best quality + speed)
./scripts/switch-model.sh nvfp4        # Qwen3.6-27B NVFP4-MTP, 131K
./scripts/switch-model.sh nvfp4-262k   # Qwen3.6-27B NVFP4-MTP, 262K (experimental)

# Status, logs, stop
./scripts/switch-model.sh status       # Running models + GPU info
./scripts/switch-model.sh logs         # Follow logs of running model
./scripts/switch-model.sh stop         # Stop all user-space models
```

Uses systemd user units (`rtx-*`) via `systemd-run`. No sudo needed. Automatically handles:
- Legacy system service cleanup (`llama-server-*` units)
- GPU memory wait loop (20GB target, 60s timeout)
- Stray process cleanup on port 10500

### Model Registry

Models are declared in `config/models.yaml`. Run `./scripts/switch-model.sh list` to see all registered models. Keys support aliases (`nvfp4`, `daily-driver`, `default`).

### Deprecated: Legacy System Services

The old `service-switcher.sh` and `/opt/`-based setup are **deprecated**. They required sudo, installed to system paths, and used legacy systemd services. The new user-space approach replaces them entirely.

If you have an existing `/opt/` install:
```fish
# Stop legacy services (requires sudo)
sudo systemctl disable --now llama-server-nvfp4-mtp-131k 2>/dev/null
sudo rm -f /etc/systemd/system/llama-server-*.service

# Remove old build + models (verify user-space copy exists first!)
ls ~/.local/share/rtx-testing/models/qwen3.6-27b-nvfp4-mtp/ && sudo rm -rf /opt/llama-mtp/ /opt/models-mtp/
```

### Other Models (Deprecated Scripts)

These scripts still work but are not maintained — use `setup-mtp.sh` instead:
```fish
sudo bash llama/setup-gemma4.sh              # Gemma 4 31B
sudo bash llama/setup-gemma4-mtp.sh          # Gemma 4 31B MTP (AtomicBot fork, TurboQuant)
sudo bash llama/setup-26b-a4b.sh             # Gemma 4 26B-A4B MoE
sudo bash llama/setup-e4b.sh                 # Qwen3.6-E4B
```

## Chat Templates

All services use Jinja chat templates (`--jinja --chat-template-file`) for consistent multimodal rendering. The shared template at `config/chat_template.jinja` handles image/video counting and thinking token preservation. Deployed to `~/.config/rtx-testing/chat_template.jinja` by `switch-model.sh`.

## Benchmarking

### Tool-Eval Benchmark

```fish
./benchmarks/run-tool-bench.sh                    # Full 69-scenario benchmark on port 10500
./benchmarks/run-tool-bench.sh --short            # Quick 15-scenario benchmark
./benchmarks/run-tool-bench.sh --port 10503       # Test a different server port
```

Uses `tool-eval-bench` against running llama-server. Results saved to `runs/` directory.

### Results

**Best result:** Qwen3.6-27B NVFP4-MTP GGUF — **93/100**, 1.2s median, best context tracking.

Full benchmark results and comparisons: [`benchmarks/results.md`](benchmarks/results.md)

## OpenCode Config

Template at `opencode/opencode.json.tlp` — copy to `~/.config/opencode/opencode.json`. Default model: `llama-qwen/qwen3.6-27b`.

| Provider | Model | Backend | Notes |
| --- | --- | --- | --- |
| `llama-nvfp4-mtp` | Qwen3.6-27B NVFP4-MTP GGUF | llama.cpp | **Daily driver**, 131K/262K, vision |
| `llama-qwen` | Qwen3.6-27B Dense | llama.cpp | Q4_K_XL, 131K |

Switch models: `opencode --model llama-nvfp4-mtp/qwen3.6-27b-nvfp4-mtp-gguf`

Context limit note: keep OpenCode context below full server capacity. The server hosts 131K, but advertising all of it lets OpenCode send very large prompts that spend most of their time in prompt evaluation.

### Persistent Memory Plugin

```fish
sudo paru -S bun                                    # Bun runtime
cp opencode-mem/opencode-mem.jsonc ~/.config/opencode/
cp opencode-mem/loader.js ~/.config/opencode/plugins/
bash opencode-mem/fix-sharp.sh                      # Fix sharp native binaries
```

Memory processing uses local model via `localhost:10500`. Embeddings run in-process on CPU RAM (~1-2GB). Web UI at `http://127.0.0.1:4747`.

### Claude Code Proxy

```fish
bash free-claude-code/install.sh    # Proxy + fish alias + VS Code extension config
claude                              # CLI
```

Uses local model through free-claude-code proxy. Works in terminal and VS Code.

## Performance (Benchmarked)

Benchmarked on RTX 5090, CUDA 13.3, Blackwell sm_120 (June 2026).

### Best Result: Qwen3.6-27B NVFP4-MTP GGUF

| Metric | Value |
| --- | --- |
| Tool-calling quality | **93/100** (best of all backends) |
| Median tool response | **1.2s** |
| Model size | 19.7 GB (NVFP4 GGUF) |
| Context | 131K (expandable to 262K with q4_1 KV) |
| Speculative decoding | MTP draft-mtp, n_max=2 |

**Why NVFP4-MTP wins:** Highest quality (93), fastest median time (1.2s), and best context tracking — all in one package. The NVFP4 quantization preserves more precision than Q4_K_XL (+3pts over Q4-MTP), while MTP speculative decoding provides the speed boost (~1.9x faster than no-MTP). Native Blackwell tensor core support (PR #22196) makes NVFP4 compute-efficient on sm_120.

### Performance Notes

- **Token generation:** ~195 t/s with MTP draft acceptance
- **VRAM usage:** ~27 GB / 32 GB at 131K context with bf16 KV cache
- **Power draw:** 475W (recommended limit), GPU temp 71-78°C

Full benchmark results with all backends compared: [`benchmarks/results.md`](benchmarks/results.md)

## Gemma 4 31B MTP (AtomicBot Fork)

Uses AtomicBot-ai/atomic-llama-cpp-turboquant with `--mtp-head` for Gemma 4's separate assistant drafter head (~0.5B params). Requires `--spec-type mtp` (not `draft-mtp`). NOTE: Gemma 4 MTP uses a different build path and is NOT unified into setup-mtp.sh yet — use `setup-gemma4-mtp.sh`.

### Setup

```fish
sudo bash llama/setup-gemma4-mtp.sh              # Install to /opt/llama.cpp-gemma4-mtp/, port 10503
sudo bash llama/setup-gemma4-mtp.sh --test       # Test install, port 10502
sudo bash llama/setup-gemma4-mtp.sh --update     # Refresh build + services (keeps models)
```

### Key Flags

| Flag | Purpose |
| --- | --- |
| `--mtp-head` | Path to assistant drafter GGUF (~0.5B params, 337MB Q4_K_M) |
| `--spec-type mtp` | Enable Gemma 4 MTP speculative decoding |
| `--draft-block-size 3` | Tokens drafter predicts per step (sweet spot for 31B) |
| `--draft-max 8` | Max draft tokens verified per step |
| `--ngld 99` | Full GPU offload for drafter (critical) |
| `-ctk turbo3` | TurboQuant KV cache (~4.3x compression) |
| `-fa on` | Flash attention |

### Expected Performance (RTX 5090)

| Mode | Tokens/sec |
| --- | --- |
| Baseline (no MTP) | ~40-60 t/s |
| With MTP + TurboQuant | ~60-90+ t/s (short prompts) |
| Acceptance rate | ~88% short, ~71% long |

### Models

- **Target:** unsloth/gemma-4-31B-it-GGUF (Q4_K_XL, ~19 GB)
- **Assistant:** AtomicChat/gemma-4-31B-it-assistant-GGUF (Q4_K_M, ~337 MB)

## KV Cache Types

Use `-ctk` and `-ctv` to control key/value cache precision. bf16 recommended for quality, q4_1 for VRAM savings.

| Type | Compression | Notes |
| --- | --- | --- |
| `bf16` | 1x | **Recommended** — best quality, ~8 GB at 131K |
| `q8_0` | ~0.5x | Minimal quality loss |
| `q5_0` / `q5_1` | ~0.6x | Good balance |
| `q4_1` | ~3x | VRAM savings, 1.3 GB at 131K (may cause attention collapse) |
| `q4_0` | ~3x | **Avoid** — CUDA bug: 5-10x slowdown past 4K context |
| `turbo3` | ~4x | TurboQuant, Gemma 4 MTP drafter only |

## Manual Setup

### 1. Verify CUDA

```fish
nvidia-smi
nvcc --version    # Cuda compilation tools, release 13.3
```

### 2. Build llama.cpp (MTP) — User-Space

```fish
paru -S --needed base-devel cmake git uv gcc15 aria2

# User-space setup (recommended):
bash llama/setup-mtp.sh --model nvfp4
```

### 3. Start Server (User-Space, MTP, 131K)

```fish
./scripts/switch-model.sh nvfp4
```

bf16 KV cache prevents attention collapse over long contexts. Draft cache (`-ctkd/-ctvd`) can stay q4_1 since it's discarded per step.

### User-Space Systemd Service

The new `switch-model.sh` uses `systemd-run --user` for background management (no sudo):

```fish
# Status
./scripts/switch-model.sh status

# Logs
journalctl --user -u rtx-qwen3-6-27b-nvfp4-mtp-131k -f

# Stop
systemctl --user stop rtx-qwen3-6-27b-nvfp4-mtp-131k
```

Requires `nvidia-persistenced` to prevent GPU memory leaks:
```fish
sudo systemctl enable --now nvidia-persistenced
```

## Model Parameters

| Model | temp | top_p | top_k | min_p |
| --- | --- | --- | --- | --- |
| Qwen3.6-27B MTP (coding) | 0.6 | 0.95 | 20 | 0.0 |
| Qwen3.6-27B (thinking off) | 0.7 | 0.8 | 20 | 0.0 |
| Gemma 4 31B (default) | 1.0 | 0.95 | 64 | — |
| Gemma 4 31B (coding) | 0.7 | 0.95 | 64 | — |

Disable thinking per-request:
```json
{"chat_template_kwargs": {"enable_thinking": false}}
```

## Monitoring

### GPU Cooling

RTX 5090 runs 80°C+ under full load. NVIDIA driver handles fans automatically.

```fish
# Reduce power limit: 575W → 500W (5-8°C cooler, ~1-2 t/s tradeoff)
sudo nvidia-smi -pl 500
```

### Netdata (recommended)

```fish
sudo pacman -S netdata
sudo systemctl enable --now netdata
# Dashboard: http://localhost:19999
```

### Quick Tools

```fish
nvtop              # GPU process monitor (like htop for GPUs)
btop               # System monitor
nvidia-smi --query-gpu=temperature.gpu,power.draw,clocks.gr --format=csv
```

## Known Issues

| Symptom | Cause | Fix |
| --- | --- | --- |
| CPU-only inference (~3.5 t/s) | Prebuilt CUDA 12.x binaries | Build from source |
| `yay: command not found` | CachyOS uses paru | `paru -S <pkg>` |
| `source activate` fails in fish | Wrong shell | `source activate.fish` |
| `huggingface-cli` not found | Renamed to `hf` | `hf download ...` |
| mmproj 404 on download | Wrong filename | Use `mmproj-F16.gguf` |
| OpenCode spinner, no response | Thinking tokens not handled | Set `enable_thinking: false` |
| `forcing full prompt re-processing` | Missing flag | Add `-ctxcp 0` (non-MTP) or `-ctxcp 64` (MTP) |
| `cudaMalloc: out of memory` | Context too large | Reduce `-c` to 131072 |
| `nvcc: command not found` | Not in PATH | `fish_add_path /opt/cuda/bin` |
| `Unsupported cache type: 7` | `-ctk` expects type name | Use `-ctk q4_1` not `-ctk 7` |
| Turbo 5-10x slow past 4K | `q4_0` CUDA bug | Use `q4_1` instead |
| CUDA 13.3 gibberish output | IQ4_XS extreme quant bug | Use UD-Q4_K_XL (unaffected) |
| Ollama unsupported | Separate mmproj file | Ollama doesn't support mmproj |
| opencode-mem sharp broken | Bun skips lifecycle scripts | Use `fix-sharp.sh` + local loader |
| `LD_LIBRARY_PATH` silent CPU fallback | Symlink path resolution | Fixed in `switch-model.sh` (readlink -f) |

## Links

| Resource | URL |
| --- | --- |
| Qwen Fixed Chat Templates | https://huggingface.co/froggeric/Qwen-Fixed-Chat-Templates |
| Qwen3.6-27B | https://huggingface.co/Qwen/Qwen3.6-27B |
| NVFP4-MTP GGUF (Qwen) | https://huggingface.co/nilayparikh/Qwen3.6-27B-Text-NVFP4-MTP-GGUF |
| NVFP4-MTP safetensors (Qwen) | https://huggingface.co/sakamakismile/Qwen3.6-27B-Text-NVFP4-MTP |
| Unsloth GGUF (Qwen MTP) | https://huggingface.co/unsloth/Qwen3.6-27B-MTP-GGUF |
| Unsloth GGUF (Qwen non-MTP) | https://huggingface.co/unsloth/Qwen3.6-27B-GGUF |
| Unsloth GGUF (Qwen3.6-35B-A3B MTP) | https://huggingface.co/unsloth/Qwen3.6-35B-A3B-MTP-GGUF |
| Gemma 4 31B | https://deepmind.google/models/gemma/gemma-4/ |
| Unsloth GGUF (Gemma 4) | https://huggingface.co/unsloth/gemma-4-31B-it-GGUF |
| llama.cpp | https://github.com/ggml-org/llama.cpp |
| MTP PR #22673 | https://github.com/ggml-org/llama.cpp/pull/22673 |
| am17an fork (MTP) | https://github.com/am17an/llama.cpp |
| Unsloth fork (MTP) | https://github.com/unslothai/llama.cpp |
| OpenCode | https://opencode.ai |
| DuckDuckGo MCP | https://pypi.org/project/duckduckgo-mcp-server/ |
| FLUX.1-schnell GGUF | https://huggingface.co/city96/FLUX.1-schnell-gguf |

## Architecture

### Configuration Layer (new)

The `config/` directory provides a declarative model registry:

```
config/
├── models.yaml              # Model definitions (path, quant, context, args)
├── backends.yaml            # Backend runtime config (llama.cpp, vLLM, etc.)
├── profiles.yaml            # Service groupings / compose profiles
└── chat-template-version.json  # Template versioning metadata
```

**Model Registry:** Each model in `config/models.yaml` declares its display name, aliases, HuggingFace repo, server arguments, and context safety tier. The switcher reads this to resolve model names without hardcoded knowledge.

### Scripts (updated)

```
scripts/
├── switch-model.sh          # User-space model switcher (systemd user units, no sudo)
├── diagnose.sh              # Runtime diagnostics: GPU, driver, services, template hash
├── build-manifest.sh        # Reproducibility package: git, system, GPU, template metadata
└── mtp-bench.py             # MTP-specific benchmarking (existing)
```

**switch-model.sh:** Resolves model keys from `config/models.yaml`, warns on experimental context tiers, starts the correct user-space systemd unit. Handles legacy system service cleanup, GPU memory waiting, and stray process killing during model switches.

**diagnose.sh:** Outputs GPU model, driver version, CUDA version, running services, active model, context size, KV cache mode, VRAM usage, and chat template hash. Supports `--json` for CI integration.

### User-Space Build Layout

```
~/.local/share/rtx-testing/
├── llama.cpp-nvfp4/         # llama.cpp build (git clone + MTP PR merge)
│   ├── build/bin/llama-server  # Main binary
│   ├── build/bin/libggml-*.so  # Shared libraries (CUDA, CPU, base)
│   └── chat_template.jinja     # Copied from repo
├── models/                  # Downloaded model files
│   └── qwen3.6-27b-nvfp4-mtp/
│       ├── qwen3.6-27b-text-nvfp4-mtp.gguf  (19.7 GB)
│       └── mmproj-F16.gguf                  (885 MB)
├── .venv-hf/                # HuggingFace CLI venv (isolated, user-space)
└── dgemma-gguf/             # Other tooling (unrelated)

~/.local/bin/llama-server → ~/.local/share/rtx-testing/llama.cpp-nvfp4/build/bin/llama-server

~/.config/rtx-testing/
└── chat_template.jinja      # Active chat template (copied by switch-model.sh)
```

### Context Safety Tiers

Models with context sizes outside the stable range are flagged in `config/models.yaml`:

| Tier | Range | Models |
| --- | --- | --- |
| **Stable** | 8K – 131K | Default for all models |
| **Experimental** | 262K | NVFP4-MTP-262K |
| **Research** | 1M+ | Not currently deployed |

`switch-model.sh` warns when starting experimental-tier models.

## Repo Structure

```text
├── config/                       # Declarative configuration
│   ├── models.yaml               # Model registry
│   ├── backends.yaml             # Backend definitions
│   ├── profiles.yaml             # Service groupings
│   ├── chat_template.jinja       # Jinja chat template (source of truth)
│   └── chat-template-version.json
├── llama/                        # llama.cpp server setup
│   ├── setup-mtp.sh              # Unified user-space MTP setup ⭐
│   │                             #   --model nvfp4 [--update]
│   ├── chat_template.jinja       # Jinja chat template (upstream copy)
│   ├── setup-qwen36-27b-mtp.sh   # Qwen3.6-27B Unsloth MTP (DEPRECATED)
│   ├── setup-qwen36-35b-mtp.sh   # Qwen3.6-35B-A3B Unsloth MTP (DEPRECATED)
│   ├── setup-qwen36-mtp.sh       # Old MTP setup (DEPRECATED)
│   ├── setup-gemma4.sh           # Gemma 4 31B
│   ├── setup-gemma4-mtp.sh       # Gemma 4 31B MTP (AtomicBot fork, separate build)
│   ├── setup-26b-a4b.sh          # Gemma 4 26B-A4B MoE
│   ├── setup-e4b.sh              # Qwen3.6-E4B
│   └── services/                 # Legacy systemd units (deprecated)
├── scripts/                      # Operational tooling
│   ├── switch-model.sh           # User-space model switcher ⭐ (no sudo)
│   ├── diagnose.sh               # Runtime diagnostics
│   ├── build-manifest.sh         # Reproducibility manifest
│   ├── service-switcher.sh       # Legacy switcher (deprecated)
│   └── nvfp4_quantize.py         # NVFP4 quantization pipeline
├── benchmarks/                   # Benchmark runners + results
│   ├── benchmark-improved.py     # Variance-aware benchmark
│   ├── benchmark.py              # General benchmark
│   ├── run-tool-bench.sh         # Tool-eval benchmark runner
│   └── results.md                # Full benchmark results summary
├── opencode/                     # OpenCode config templates
├── opencode-mem/                 # Persistent memory plugin for OpenCode
├── docs/                         # Documentation
└── system/                       # Hardware monitoring configs
```

---

MIT. [felippeburk](https://gitlab.com/felippeburk). Based on [jamesarslan/local-ai-coding-setup](https://github.com/jamesarslan/local-ai-coding-setup).
