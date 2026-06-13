# RTX 5090 Local AI — Agent Instructions

## Daily Driver: Qwen3.6-27B NVFP4-MTP (131K)

### Start / Stop / Status

```bash
# Start the daily driver model
./scripts/switch-model.sh nvfp4

# Check status and GPU info
./scripts/switch-model.sh status

# Follow logs
./scripts/switch-model.sh logs

# Stop all user-space models
./scripts/switch-model.sh stop
```

### Fresh Install (no sudo)

```bash
bash llama/setup-mtp.sh --model nvfp4     # Build + download models
bash llama/setup-mtp.sh --update          # Rebuild only, keep models
```

Builds to `~/.local/share/rtx-testing/llama.cpp-nvfp4/`, models to `~/.local/share/rtx-testing/models/`.

### Diagnostics

```bash
./scripts/diagnose.sh        # GPU, driver, services, template hash
./scripts/diagnose.sh --json # Machine-readable output
```

### Benchmarks

```bash
./benchmarks/run-tool-bench.sh           # Full 69-scenario tool-eval benchmark
./benchmarks/run-tool-bench.sh --short   # Quick 15-scenario benchmark
python3 benchmarks/humaneval.py          # HumanEval pass@k evaluation
python3 scripts/mtp-bench.py             # MTP speculative decoding benchmark
```

### NEVER DO

- Never stop the running model server without explicit user consent
- The `switch-model.sh` script handles stopping old models — let it do its job
- Do not use Docker or vLLM — user-space llama.cpp only
- Do not modify `pi/` config files in this repo — they affect live Pi sessions
