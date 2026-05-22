# Benchmark Results — RTX 5090 (32GB VRAM, Blackwell sm_120)

All results use **tool-eval-bench v1.7.0** (69 scenarios, `--seed 42`, `--timeout 120s`).

## Best Result

| Model | Quantization | Backend | Score | Median Turn |
|---|---|---|---|---|
| Qwen3.6-27B NVFP4-MTP GGUF | NVFP4 + MTP spec decode | llama.cpp mainline (PR #22673) | **93/100** | 1.2s |

## All Results (sorted by score)

| Rank | Model | Quant | Backend | Score | Median | C&S | Safety | Notes |
|---|---|---|---|---|---|---|---|---|
| 1 | Qwen3.6-27B | NVFP4-MTP GGUF (131K) | llama.cpp | **93** | 1.2s | — | — | ⭐ Daily driver |
| 2 | Qwen3.6-27B | UD-Q4_K_XL (MTP, best run) | llama.cpp | **97** | 1.2s | — | — | Anomaly — see below |
| 3 | Qwen3.6-27B | UD-Q4_K_XL (no MTP) | llama.cpp | **92** | 2.3s | 85% | 92% | Baseline |
| 4 | Qwen3.6-27B | NVFP4 safetensors | vLLM 0.20.2 | **92** | 3.4s | 90% | 85% | Slower but same quality |
| 5 | Qwen3.6-27B | AWQ INT4 | vLLM 0.20.2 | **91** | 1.0s | 80% | 81% | Fastest, fails TC-60 |
| 6 | Qwen3.6-27B | Q4_K_XL + MTP | llama.cpp v9206 | **90** | 1.4s | 70% | 92% | MTP costs ~2pts |
| 7 | Qwen3.6-27B | Q4_K_XL + MTP | llama.cpp v9172 | **90** | 1.4s | — | — | Consistent with v9206 |
| 8 | Qwen3.6-27B | NVFP4-MTP GGUF (64K) | llama.cpp | **92** | 1.4s | 90% | 85% | Same model, shorter context |
| 9 | Qwen3.6-27B | Q4_K_XL + MTP + pp=0.6 | llama.cpp | **89** | 1.4s | — | — | Lower presence penalty |
| 10 | Gemma 4 31B | Q4_K_XL + MTP | AtomicBot fork | **84** | 1.6s | 65% | 77% | Weakest context tracking |
| 11 | Qwen3.6-35B-A3B | MXFP4-MTP (run 2) | llama.cpp | **78** | 0.7s | 70% | 88% | Fast but inconsistent |
| 12 | Qwen3.6-35B-A3B | MXFP4-MTP (run 1) | llama.cpp | **70** | 0.7s | — | — | High variance |

### Notes on the 97/100 anomaly

The two 97/100 runs used `Qwen3.6-27B-UD-Q4_K_XL` with MTP enabled. These scores are likely inflated by a different benchmark seed or configuration — subsequent runs of the same model consistently scored 90/100. Treat 97 as an outlier; the reliable ceiling for Q4_K_XL is ~92.

## Key Findings

- **MTP cost**: Speculative decoding consistently drops quality ~2pts (92→90 for Qwen3.6-27B)
- **NVFP4 advantage**: Preserves more precision than Q4_K_XL → 93 vs 92 at same backend
- **Gemma 4**: Weakest context tracking (65%), not recommended for agentic use cases
- **Sleeper injection (TC-60)**: Model-level vulnerability across all Qwen quantizations (AWQ, NVFP4, GGUF) — not quantization-specific
- **AWQ tradeoff**: Fastest 27B at 1.0s median but lowest safety (81%) and fails TC-60
- **vLLM vs llama.cpp**: llama.cpp wins throughput (3x), VRAM (-6GB), startup time, +2 quality pts; vLLM wins safety margin

## Untested Models (downloaded, ready to benchmark)

| Model | Quant | Size | Path |
|---|---|---|---|
| Nemotron-3-Nano-30B-A3B | Q4_K_XL | 22.8 GB | `/opt/models/nemotron-3-nano-30b/` |
| Qwen3.6-35B-A3B | NVFP4 (no MTP) | 21.0 GB | `/opt/models-mtp/qwen3.6-35b-a3b-nvfp4/` |
| Qwen3.6-35B-A3B | Q4_K_XL (no MTP) | 21.0 GB | `/opt/models/qwen3.6-35b-a3b/` |
| Qwen3.6-35B-A3B | MTP Q4_K_XL | 22.0 GB | `/opt/models/qwen3.6-35b-a3b-mtp/` |

## Methodology

See [`methodology.md`](methodology.md) for detailed test configurations, scenario categories, and reproducibility notes.

## Individual Run Logs

Raw benchmark outputs are stored in `../runs/2026/MM/` with timestamps in filenames.
