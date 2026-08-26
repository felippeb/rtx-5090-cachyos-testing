# KV Cache Quantization A/B — bf16 vs q8_0

**Date:** 2026-08-26 · **Model:** Qwen3.8-27B NVFP4-MTP GGUF · **Backend:** llama.cpp mainline + MTP PR #22673
**Question:** does q8_0 K/V cache cost measurable quality vs bf16? (q8_0 halves KV memory and is what makes the 192Ki context tier possible.)

## Setup

Identical configs except `-ctk`/`-ctv`. Both legs at `-c 131072` (the largest context where bf16 still fits), fixed bench seed:

```
-m qwen3.8-27b-text-nvfp4-mtp.gguf --mmproj mmproj-F16.gguf \
-fitt 8192 -c 131072 -n 65536 -fa on -ngl 99 -np 1 -t 16 -tb 16 \
-ctk <bf16|q8_0> -ctv <bf16|q8_0> -ctkd q4_1 -ctvd q4_1 -ctxcp 16 \
--spec-type draft-mtp --spec-draft-n-max 2 \
--temp 1.0 --top-p 0.95 --top-k 20 --min-p 0.0 \
--reasoning on --reasoning-budget 4096 --chat-template-kwargs '{"reasoning_effort":"xhigh"}'
```

Benchmark: `./benchmarks/run-tool-bench.sh --short` (15 scenarios, `--seed 42`, tool-eval-bench v1.7.0).

## Results

| Leg | KV cache | Score | Points | Median turn | Responsiveness | Deployability |
|---|---|---|---|---|---|---|
| A | bf16 | 93/100 | 28/30 (TC-06 multi-value extraction ❌) | 1.0s | 84 | 90 |
| B | q8_0 | **100/100** | 30/30 ✅ | 1.0s | 84 | 95 |

## Verdict

**No measurable quality penalty for q8_0.** The single flipped scenario is within run-to-run noise at temp 1.0 sampling (single run per leg; see the 97/100 anomaly note in [results.md](results.md) for how much single-run scores can wobble). Combined with q8_0 using exactly half the KV memory per token (32 KiB vs 64 KiB/token on this model), q8_0 is the default choice above 131K context — and costs nothing at any context.

Caveats: tool-calling quality at 131K only; long-context recall at 192Ki was not separately evaluated.

## Related finding: bf16 cannot reach 192Ki

bf16 K/V at `-c 196608` needs ~12 GiB of KV vs ~6 GiB for q8_0. Empirically confirmed OOM during load (2026-08-26):

```
ggml_backend_cuda_buffer_type_alloc_buffer: allocating 1040.28 MiB on device 0: cudaMalloc failed: out of memory
graph_reserve: failed to allocate compute buffers
```

Practical bf16 ceiling with weights (~19 GB) + mmproj (885 MB) on a 32 GB card is **~160K context** (`-c 163840`); 168K is razor-thin and 196608 does not fit. This is why the registry's 192Ki/196K tiers (`qwen3.8-27b-nvfp4-mtp-196k`, Huihui 192k) use `-ctk q8_0 -ctv q8_0`.

## Reproduce

```bash
./scripts/switch-model.sh stop
# start llama-server with either leg's args above, then:
./benchmarks/run-tool-bench.sh --short
```

Raw outputs: `/tmp/opencode/kv-ab-{bf16,q80}-result.txt`; run reports under `runs/2026/08/`.
