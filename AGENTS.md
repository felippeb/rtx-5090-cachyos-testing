# RTX 5090 Local AI — Agent Instructions

## Daily Driver: Qwen3.8-27B NVFP4-MTP (196K)

### Start / Stop / Status

```bash
# Start the daily driver model
./scripts/switch-model.sh nvfp4-196k
# Other registered models (see config/models.yaml): huihui (Huihui-Qwen3.8-27B abliterated)
./scripts/switch-model.sh huihui

# Check status and GPU info
./scripts/switch-model.sh status

# Follow logs
./scripts/switch-model.sh logs

# Stop all user-space models
./scripts/switch-model.sh stop
```

### Fresh Install (no sudo)

```bash
bash llama/setup-mtp.sh --model qwen38   # Build + download + convert models
bash llama/setup-mtp.sh --update         # Rebuild only, keep models
```

Builds to `~/.local/share/rtx-testing/llama.cpp-nvfp4/`, models to `~/.local/share/rtx-testing/models/`.

### Diagnostics

```bash
./scripts/diagnose.sh        # GPU, driver, services, template hash
./scripts/diagnose.sh --json # Machine-readable output

# Follow user-service logs (last 100 lines, tail)
journalctl --user -u rtx-qwen3-8-27b-nvfp4-mtp-196k -f -n 100
```

### Benchmarks

```bash
./benchmarks/run-tool-bench.sh           # Full 69-scenario tool-eval benchmark
./benchmarks/run-tool-bench.sh --short   # Quick 15-scenario benchmark
python3 benchmarks/humaneval.py          # HumanEval pass@k evaluation
python3 scripts/mtp-bench.py             # MTP speculative decoding benchmark
```

### mem0 — local memory layer (opencode plugin)

Self-hosted mem0 for opencode. LLM = daily driver (`:10500`), embeddings =
second llama-server (`:8080`, nomic-embed-text-v1.5), mem0 API on `:8001`
(FastAPI wrapper over `mem0.Memory`, Qdrant embedded store).

```bash
./scripts/mem0-setup.sh             # Idempotent: bring up / verify the whole stack
journalctl --user -u mem0-api -f    # API logs (uvicorn)
journalctl --user -u llama-embed -f # embedding llama-server logs
```

- Services are `systemd-run --user` units `llama-embed` + `mem0-api`
  (Restart=on-failure). Named to avoid `switch-model.sh stop_existing`
  (`rtx-*`/`llama-server-*` globs) killing them on model switches.
- Plugin: `@fables092/opencode-mem0` in `opencode.json`; reads
  `~/.config/opencode/mem0.jsonc` (baseUrl `http://localhost:8001`).
- `mem0-server/app.py` exposes `POST /memories`, `GET /memories`,
  `DELETE /memories/{id}`, `POST /search` (plugin's expected surface).
- Data in `~/.local/share/rtx-testing/mem0/` (Qdrant + SQLite history).
- `:8000` is taken by the duckduckgo MCP server — mem0 is on `:8001`.

### dsh — DeepSeek Harness Web GUI

The DeepSeek Harness checkout (`~/repos/github/deepseek-harness`,
`pnpm dsh web`) served as a user service on `:3080`.

```bash
./scripts/dsh-web.sh start     # start (transient systemd user unit dsh-web)
./scripts/dsh-web.sh stop      # stop
./scripts/dsh-web.sh status    # running? PID + URL
./scripts/dsh-web.sh logs      # last 50 lines; `logs -f` to follow
```

- Same `systemd-run --user --collect` pattern as mem0 (Restart=on-failure);
  unit name `dsh-web` avoids the `switch-model.sh` stop globs.
- Transient: does not survive reboot. Requires built artifacts
  (`cd ~/repos/github/deepseek-harness && pnpm run build`).
- Port override: `DSH_WEB_PORT=4000 ./scripts/dsh-web.sh start`.

### NEVER DO

- Never stop the running model server without explicit user consent
- The `switch-model.sh` script handles stopping old models — let it do its job
- Do not use Docker or vLLM — user-space llama.cpp only
- Do not modify `pi/` config files in this repo — they affect live Pi sessions
