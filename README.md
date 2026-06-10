# RTX 5090 Local AI Setup (CachyOS)

Local AI coding environment on CachyOS with NVIDIA RTX 5090.

**Daily driver:** Qwen3.6-27B NVFP4-MTP (131K context) via llama.cpp mainline | NVFP4 GGUF | Best overall quality + speed (93/100, 1.2s median).

## Stack

| Component | Details |
| --- | --- |
| GPU | NVIDIA RTX 5090 (32GB GDDR7, Blackwell sm_120) |
| OS | CachyOS (Arch-based, KDE Plasma, Wayland) |
| Shell | fish |
| CUDA | 13.2 (V13.2.78, driver 595.58.03) |
| Runtime | llama.cpp mainline (ggml-org) + MTP PR #22673 (NVFP4 native), vLLM |
| Default model | Qwen3.6-27B NVFP4-MTP (19.7 GB, 131K context, NVFP4 + speculative decoding) |
| Alt models | Qwen3.6-27B MTP Q4_K_XL, Qwen3.6-35B-A3B MTP, Gemma 4 31B, Gemma 4 26B-A4B |
| vLLM variants | AWQ/FP8/NVFP4 for Qwen3.6-27B, Qwen3.6-35B-A3B, Gemma 4 31B |
| Image gen | FLUX.1-schnell (GGUF Q2_K quantized) |
| UI | OpenCode, Claude Code (CLI + VS Code), Open WebUI |
| MCP tools | Context7 docs, Chrome DevTools, DuckDuckGo search, DesignMD |
| Web search | DuckDuckGo MCP server (Docker, port 8000) |
| Package manager | pacman / paru |

## Build Layout

Two separate llama.cpp builds:

| Build | Path | Branch/PR | Models |
| --- | --- | --- | --- |
| **llama-mtp** | `/opt/llama-mtp/` | ggml-org mainline + MTP PR #22673 | Qwen3.6-27B MTP, Qwen3.6-27B NVFP4-MTP, Qwen3.6-35B-A3B MTP |
| **llama.cpp** | `/opt/llama.cpp/` | am17an fork (mtp-clean) | Non-MTP models, Gemma 4 MTP (AtomicBot) |

## Quick Start

### Unified MTP Setup (Recommended)

```fish
sudo bash llama/setup-mtp.sh --model nvfp4          # Qwen3.6-27B NVFP4-MTP (~20GB) ⭐ daily driver
sudo bash llama/setup-mtp.sh --model 27b            # Qwen3.6-27B MTP Q4_K_XL (~11GB)
sudo bash llama/setup-mtp.sh --model 35b            # Qwen3.6-35B-A3B MTP (~23GB)
sudo bash llama/setup-mtp.sh --all                  # All models
sudo bash llama/setup-mtp.sh --all --update          # Rebuild llama.cpp only (keeps models)
sudo bash llama/setup-mtp.sh --model nvfp4 --test   # Test install: /opt/llama-mtp-test/, port 10502
```

Builds llama.cpp from mainline (ggml-org) with MTP PR #22673 grafted on. Installs to `/opt/llama-mtp/`, models to `/opt/models-mtp/`. Idempotent — re-runs skip what's installed.

### Deprecated Setup Scripts

The following scripts are **deprecated** in favor of `setup-mtp.sh`:
- `setup-qwen36-mtp.sh` — old MTP setup (havenoammo PR graft)
- `setup-qwen36-27b-mtp.sh` — Unsloth MTP build for 27B
- `setup-qwen36-35b-mtp.sh` — Unsloth MTP build for 35B

Still functional but not maintained. Use `setup-mtp.sh` instead.

### Other Models

```fish
sudo bash llama/setup-gemma4.sh              # Gemma 4 31B
sudo bash llama/setup-gemma4-mtp.sh          # Gemma 4 31B MTP (AtomicBot fork, TurboQuant)
sudo bash llama/setup-26b-a4b.sh             # Gemma 4 26B-A4B MoE
sudo bash llama/setup-e4b.sh                 # Qwen3.6-E4B
```

### Switch Between Models

```fish
# ⭐ NVFP4-MTP (daily driver — best quality + speed)
./scripts/service-switcher.sh nvfp4-mtp-llama-131k  # Qwen3.6-27B NVFP4-MTP GGUF, 131K
./scripts/service-switcher.sh nvfp4-mtp-llama-262k  # Qwen3.6-27B NVFP4-MTP GGUF, 262K (q4_1 KV)

# Qwen3.6-27B MTP (Q4_K_XL quant)
./scripts/service-switcher.sh mtp-131k           # Qwen3.6-27B MTP, 131K

# Qwen3.6-35B-A3B variants
./scripts/service-switcher.sh 35b-mtp-131k      # Qwen3.6-35B-A3B MTP, 131K (Q4_K_XL)
./scripts/service-switcher.sh 35b-mxfp4-mtp-131k   # 35B MXFP4-MTP, 131K (spec decode n=6)
./scripts/service-switcher.sh 35b-nvfp4-131k    # 35B NVFP4 (no MTP), 131K

# Non-MTP models
./scripts/service-switcher.sh turbo             # Qwen3.6-27B non-MTP, 131K (bf16 KV)
./scripts/service-switcher.sh qwen              # Qwen3.6-27B non-MTP, 131K (q8_0 KV)
./scripts/service-switcher.sh gemma4-turbo      # Gemma 4 31B, 131K (q4_1 KV)
./scripts/service-switcher.sh gemma4            # Gemma 4 31B, 131K (f16 KV)
./scripts/service-switcher.sh gemma4-mtp-131k   # Gemma 4 31B MTP, 131K (AtomicBot fork)
./scripts/service-switcher.sh qwen35b-turbo     # Qwen3.6-35B-A3B, 131K (q4_1 KV)
./scripts/service-switcher.sh qwen35b           # Qwen3.6-35B-A3B, 131K
./scripts/service-switcher.sh e4b               # Gemma 4 E4B-it, 128K (vision + thinking)
./scripts/service-switcher.sh a4b               # Gemma 4 26B-A4B MoE, 128K
./scripts/service-switcher.sh stop              # Stop all servers
```

### vLLM Services

```fish
# NVFP4 (with/without MTP)
./scripts/service-switcher.sh nvfp4-mtp                 # NVFP4-MTP vLLM, 131K (modelopt + MTP n=3)
./scripts/service-switcher.sh nvfp4-mtp-turbo           # NVFP4-MTP vLLM, 256K (modelopt + MTP n=3)
./scripts/service-switcher.sh nvfp4-turbo               # NVFP4, 131K (compressed-tensors)
./scripts/service-switcher.sh nvfp4                     # NVFP4, 131K

# FP8
./scripts/service-switcher.sh fp8                       # FP8, 131K
./scripts/service-switcher.sh fp8-turbo                 # FP8, 131K

# AWQ INT4
./scripts/service-switcher.sh awq                       # Qwen3.6-27B AWQ INT4, 131K
./scripts/service-switcher.sh awq-turbo                 # Qwen3.6-27B AWQ INT4, 255K
./scripts/service-switcher.sh awq-35b-131k              # Qwen3.6-35B-A3B MoE AWQ, 131K
```

### Router & Swap (Experimental)

```fish
# llama.cpp router mode — native model switching without restarts
./scripts/service-switcher.sh router                     # Router on port 10500

# llama-swap proxy — Qwen + FLUX on single port
./scripts/service-switcher.sh swap                       # Swap proxy on port 9292
```

### DuckDuckGo MCP (Web Search)

```fish
./duckduckgo-mcp/start.sh              # Start container (port 8000)
./duckduckgo-mcp/start.sh --rebuild    # Rebuild image + start
./duckduckgo-mcp/stop.sh               # Stop container
```

Docker-based MCP server providing `search` and `fetch_content` tools. Rate limited (30 req/min search, 20 req/min fetch). Enabled in OpenCode config by default.

### FLUX Schnell (Image Generation)

```fish
sudo bash flux-server/setup-flux.sh              # Install and configure
sudo bash flux-server/setup-flux.sh --update     # Refresh deps (keeps model)
./flux-server/run_flux_with_prompt.py            # Generate image with prompt
```

### Open WebUI

```fish
./open-webui/start.sh              # Start (checks llama-server is running)
./open-webui/stop.sh               # Stop Open WebUI only
./open-webui/stop.sh --all         # Stop Open WebUI + llama-server
```

## Chat Templates

All services now use Jinja chat templates (`--jinja --chat-template-file`) for consistent multimodal rendering. The shared template at `llama/chat_template.jinja` handles image/video counting and thinking token preservation. Deployed to `/opt/llama-mtp/chat_template.jinja` and `/opt/llama.cpp/chat_template.jinja` by `./scripts/reapply-services.sh`.

## Benchmarking

### Tool-Eval Benchmark

```fish
./benchmarks/run-tool-bench.sh                    # Full 69-scenario benchmark on port 10500
./benchmarks/run-tool-bench.sh --short            # Quick 15-scenario benchmark
./benchmarks/run-tool-bench.sh --port 10503       # Test a different server port
./benchmarks/run-tool-bench.sh --short --seed 123 # Quick run with different seed
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
| `llama-mtp` | Qwen3.6-35B-A3B MTP | llama.cpp | Q4_K_XL, 131K |
| `llama-35b-mxfp4-mtp` | Qwen3.6-35B-A3B MXFP4-MTP | llama.cpp | Blackwell FP4, spec decode |
| `llama-35b-nvfp4` | Qwen3.6-35B-A3B NVFP4 | llama.cpp | Blackwell FP4, no MTP |
| `gemma4` | Gemma 4 31B Dense | llama.cpp | 131K |
| `gemma4-a4b` | Gemma 4 26B A4B MoE | llama.cpp | 131K |
| `e4b` | Gemma 4 E4B-it | llama.cpp | vision + thinking |
| `vllm-nvfp4-mtp` | Qwen3.6-27B NVFP4-MTP | vLLM | modelopt, 131K |
| `vllm-awq` | Qwen3.6-27B AWQ INT4 | vLLM | 131K |
| `flux` | FLUX.1-schnell | ComfyUI | Image gen, port 10501 |

Switch models: `opencode --model llama-nvfp4-mtp/qwen3.6-27b-nvfp4-mtp-gguf` or `opencode --model vllm-nvfp4-mtp/qwen3.6-27b-nvfp4-mtp`

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

Benchmarked on RTX 5090, CUDA 13.2, Blackwell sm_120 (May 2026).

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

- **Token generation:** ~126 t/s (Qwen3.6-27B MTP), ~288 t/s (Qwen3.6-35B-A3B MoE — 2.1x faster despite more params)
- **VRAM usage:** ~26 GB / 32 GB at 131K context with bf16 KV cache
- **Power draw:** 561-576W under load, GPU temp 71-78°C

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
fish_add_path /opt/cuda/bin
nvcc --version    # Cuda compilation tools, release 13.2, V13.2.78
```

### 2. Build llama.cpp (MTP)

```fish
sudo pacman -S --needed base-devel cmake git uv gcc14

# Unified MTP setup (recommended):
sudo bash llama/setup-mtp.sh --model 27b

# Or manual:
git clone --depth 1 https://github.com/ggml-org/llama.cpp.git /opt/llama-mtp
cd /opt/llama-mtp
# Graft MTP PR #22673 onto mainline

cmake -B build \
  -DGGML_CUDA=ON \
  -DGGML_NATIVE=ON \
  -DGGML_CUDA_FA=ON \
  -DGGML_CUDA_FA_ALL_QUANTS=ON \
  -DCMAKE_CUDA_ARCHITECTURES=120 \
  -DCMAKE_CUDA_COMPILER=/opt/cuda/bin/nvcc \
  -DCMAKE_CUDA_HOST_COMPILER=/usr/bin/g++-14

cmake --build build -j$(nproc)
llama-server --version    # Must show: loaded CUDA backend
```

### 3. Download Model

```fish
# NVFP4-MTP (daily driver, 19.7 GB):
hf download nilayparikh/Qwen3.6-27B-Text-NVFP4-MTP-GGUF \
  qwen3.6-27b-text-nvfp4-mtp.gguf \
  --local-dir /opt/models-mtp/qwen3.6-27b-nvfp4-mtp/

# Or Q4_K_XL MTP (16.4 GB):
hf download unsloth/Qwen3.6-27B-MTP-GGUF \
  Qwen3.6-27B-UD-Q4_K_XL.gguf \
  mmproj-F16.gguf \
  --local-dir /opt/models-mtp/qwen3.6-27b-mtp/
```

### 4. Start Server (MTP, 131K)

```fish
/opt/llama-mtp/build/bin/llama-server \
  -m /opt/models-mtp/qwen3.6-27b-mtp/Qwen3.6-27B-UD-Q4_K_XL.gguf \
  --mmproj /opt/models-mtp/qwen3.6-27b-mtp/mmproj-F16.gguf \
  -c 131072 \
  -n 32768 \
  -fa on -ngl 99 -np 1 \
  -t 16 -tb 16 \
  -ctk bf16 -ctv bf16 -ctkd q4_1 -ctvd q4_1 \
  --no-warmup \
  --spec-type draft-mtp --spec-draft-n-max 2 \
  --temp 0.6 --top-p 0.95 --top-k 20 --min-p 0.0 \
  --presence-penalty 1.5 --repeat-penalty 1.0 \
  --jinja \
  --chat-template-file /opt/llama-mtp/chat_template.jinja \
  --host 0.0.0.0 --port 10500
```

bf16 KV cache prevents attention collapse over long contexts. Draft cache (`-ctkd/-ctvd`) can stay q4_1 since it's discarded per step.

### 5. Systemd Service

```fish
sudo ./scripts/reapply-services.sh    # Deploys all services + chat templates
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
| CUDA 13.2 gibberish output | IQ4_XS extreme quant bug | Use UD-Q4_K_XL (unaffected) |
| Ollama unsupported | Separate mmproj file | Ollama doesn't support mmproj |
| opencode-mem sharp broken | Bun skips lifecycle scripts | Use `fix-sharp.sh` + local loader |

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

The `config/` directory provides a declarative model registry, replacing implicit knowledge encoded in docker-compose:

```
config/
├── models.yaml            # Model definitions (path, quant, context, service mapping)
├── backends.yaml          # Backend runtime config (llama.cpp, vLLM, etc.)
├── profiles.yaml          # Service groupings / compose profiles
└── chat-template-version.json  # Template versioning metadata
```

**Model Registry:** Each model in `config/models.yaml` declares its backend, quantization, context size, KV cache types, speculative decoding settings, and the corresponding docker-compose service. This enables tooling to query "what models exist" without parsing compose files.

### Scripts (new)

```
scripts/
├── switch-model.sh        # Registry-aware model switcher (replaces docker/switch.sh)
├── diagnose.sh            # Runtime diagnostics: GPU, driver, services, template hash
├── build-manifest.sh      # Reproducibility package: git, system, GPU, template metadata
└── mtp-bench.py           # MTP-specific benchmarking (existing)
```

**switch-model.sh:** Resolves model keys from `config/models.yaml`, warns on experimental context tiers, starts the correct compose service. Drop-in replacement for `docker/switch.sh`.

**diagnose.sh:** Outputs GPU model, driver version, CUDA version, running services, active model, context size, KV cache mode, VRAM usage, and chat template hash. Supports `--json` for CI integration.

**build-manifest.sh:** Generates `build-manifest.json` with git commit, driver/CUDA versions, kernel, template SHA256, and registry stats — the reproducibility package for benchmark runs.

### Benchmarking (improved)

`benchmarks/benchmark-improved.py` adds variance reporting to the existing benchmark suite:
- Multiple runs per prompt (default 5, configurable via `--runs`)
- Median, p95, standard deviation for gen t/s and TTFT
- Cold / warm cache mode distinction (`--mode cold|warm|all`)
- JSON output to `runs/` directory for CI tracking

### Context Safety Tiers

Models with context sizes outside the stable range are flagged in `config/models.yaml`:

| Tier | Range | Models |
| --- | --- | --- |
| **Stable** | 8K – 131K | Default for all models |
| **Experimental** | 262K | NVFP4-MTP-262K, vLLM turbo variants |
| **Research** | 1M+ | Not currently deployed |

`switch-model.sh` warns when starting experimental-tier models.

## Repo Structure

```text
├── config/                       # Declarative configuration
│   ├── models.yaml               # Model registry
│   ├── backends.yaml             # Backend definitions
│   ├── profiles.yaml             # Service groupings
│   └── chat-template-version.json
├── llama/                        # llama.cpp server setup
│   ├── setup-mtp.sh              # Unified MTP setup (mainline + PR #22673) ⭐
│   │                             #   --model 27b|35b|nvfp4
│   ├── chat_template.jinja       # Jinja chat template (from froggeric/Qwen-Fixed-Chat-Templates)
│   ├── setup-qwen36-27b-mtp.sh   # Qwen3.6-27B Unsloth MTP (DEPRECATED, use setup-mtp.sh)
│   ├── setup-qwen36-35b-mtp.sh   # Qwen3.6-35B-A3B Unsloth MTP (DEPRECATED)
│   ├── setup-qwen36-mtp.sh       # Old MTP setup (DEPRECATED)
│   ├── setup-unsloth-studio.sh   # Unsloth Studio (port 8888)
│   ├── setup-gemma4.sh           # Gemma 4 31B
│   ├── setup-gemma4-mtp.sh       # Gemma 4 31B MTP (AtomicBot fork, separate build)
│   ├── setup-26b-a4b.sh          # Gemma 4 26B-A4B MoE
│   ├── setup-e4b.sh              # Qwen3.6-E4B
│   ├── setup-qwen.sh             # Qwen3.6-27B non-MTP (legacy)
│   ├── setup-router.sh           # Router mode setup (experimental)
│   ├── kill.fish                 # Emergency kill script
│   └── services/                 # systemd units (llama-server-*.service)
├── scripts/                      # Operational tooling
│   ├── switch-model.sh           # Registry-aware model switcher
│   ├── diagnose.sh               # Runtime diagnostics
│   ├── build-manifest.sh         # Reproducibility manifest
│   ├── service-switcher.sh       # Legacy switcher (deprecated)
│   ├── reapply-services.sh       # Redeploy all systemd units + chat templates
│   └── nvfp4_quantize.py         # NVFP4 quantization pipeline
├── benchmarks/                   # Benchmark runners + results
│   ├── benchmark-improved.py     # Variance-aware benchmark (new)
│   ├── benchmark.py              # General benchmark
│   ├── run-tool-bench.sh         # Tool-eval benchmark runner
│   ├── results.md                # Full benchmark results summary
│   └── nvfp4-mtp-llama-vs-vllm.md  # Head-to-head comparison
├── duckduckgo-mcp/               # DuckDuckGo MCP server
│   ├── start.sh / stop.sh        # Container management
│   └── docker-compose.yml        # Container config
├── opencode/                     # OpenCode config templates
├── opencode-mem/                 # Persistent memory plugin for OpenCode
├── docs/                         # Documentation
├── system/                       # Hardware monitoring configs
├── browser-harness -> ...        # Symlink to browser-harness repo
└── opencode/                     # OpenCode config templates
```

---

MIT. [felippeburk](https://gitlab.com/felippeburk). Based on [jamesarslan/local-ai-coding-setup](https://github.com/jamesarslan/local-ai-coding-setup).
