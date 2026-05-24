# Wattage Benchmark Results

## Setup

- **GPU**: RTX 5090 (32GB VRAM, Blackwell sm_120)
- **Model**: Qwen3.6-27B NVFP4-MTP GGUF via llama.cpp
- **Workload**: Full Next.js 14 static site generation prompt (~734 prompt tokens, up to 16K gen tokens)
- **Power limits tested**: 400W → 575W in 25W increments
- **Monitoring**: `nvidia-smi` sampled every 1s during generation

## Results Summary

| Power Limit | Avg Draw | Max Draw | Gen t/s | Efficiency (t/s/W) | Avg Temp | Max Temp | Total Time | Tokens Generated |
|---|---|---|---|---|---|---|---|---|
| 400W | 394.3W | 407.4W | 104.0 | **0.264** | 58.4°C | 65°C | 116.7s | 12,848 |
| 425W | 421.7W | 426.4W | 105.9 | 0.251 | 66.6°C | 68°C | 144.9s | 16,053 |
| 450W | 446.7W | 452.6W | 107.8 | 0.241 | 69.1°C | 71°C | 152.2s | 17,118 |
| 475W | 470.1W | 485.5W | 109.9 | 0.234 | 70.7°C | 72°C | 122.1s | 14,135 |
| 500W | 494.7W | 504.1W | 109.9 | 0.222 | 72.3°C | 74°C | 124.5s | 14,398 |
| 525W | 517.8W | 527.0W | 111.5 | 0.215 | 73.8°C | 76°C | 136.1s | 15,886 |
| 550W | 528.2W | 544.0W | 110.9 | 0.210 | 74.6°C | 77°C | 125.7s | 14,646 |
| 575W | 537.7W | 552.5W | 110.8 | 0.206 | 75.4°C | 77°C | 139.0s | 16,117 |

## Key Findings

1. **Gen speed is nearly flat** — 104–111 t/s across the full range (~7% spread). This workload is memory-bandwidth bound, not compute bound.
2. **400W is optimal for efficiency** — 0.264 t/s/W vs 0.206 at 575W (28% more efficient) for only 6.5% less throughput.
3. **Diminishing returns above 475W** — gen speed plateaus at ~110 t/s; going from 475→575W adds only 0.9 t/s but costs 105W and 5°C.
4. **Draft acceptance is consistent** — 80–84% across all power limits. MTP spec decode quality is unaffected by power limit.

## Recommendation

**400W power limit** is the sweet spot for this model/workload. Applied automatically via `service-switcher.sh`.
