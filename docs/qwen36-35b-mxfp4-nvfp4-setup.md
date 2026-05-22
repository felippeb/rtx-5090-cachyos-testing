# Qwen3.6-35B-A3B MXFP4-MTP + NVFP4 Setup

## Background

No true **NVFP4+MTP GGUF** exists yet for Qwen3.6-35B-A3B. The two available paths:

| Format | MTP? | Source | Size | Notes |
|--------|------|--------|------|-------|
| **MXFP4 MOE** | ✅ | `unsloth/Qwen3.6-35B-A3B-MTP-GGUF` | 22.2 GB | Blackwell FP4 via llama.cpp's internal MXFP4 pack + MTP draft heads |
| **NVFP4** | ❌ | `knoopx/Qwen3.6-35B-A3B-NVFP4-GGUF` | ~21 GB | compressed-tensors GGUF, no MTP layers in conversion |

MXFP4 and NVFP4 both use Blackwell tensor core instructions — MXFP4 just uses llama.cpp's internal FP4 pack format instead of compressed-tensors. It's the **closest thing to "NVFP4 MTP"** available today.

## Files Created/Modified

### New Service Files (llama.cpp)

| File | Description |
|------|-------------|
| `llama/services/llama-server-35b-mxfp4-mtp.service` | MXFP4-MTP, 64K context, spec decode n=6 |
| `llama/services/llama-server-35b-mxfp4-mtp-131k.service` | MXFP4-MTP, 131K context, spec decode n=6 |
| `llama/services/llama-server-35b-nvfp4.service` | NVFP4 (no MTP), 64K context |
| `llama/services/llama-server-35b-nvfp4-131k.service` | NVFP4 (no MTP), 131K context |

### Modified Files

| File | Changes |
|------|---------|
| `llama/setup-mtp.sh` | Added `35b-mxfp4` and `35b-nvfp4` model definitions, service lists, default service selection, switcher shortcuts, usage text |
| `service-switcher.sh` | Added `35b-mxfp4-mtp`, `35b-mxfp4-mtp-131k`, `35b-nvfp4`, `35b-nvfp4-131k` modes to ALL_SERVICES + case statements |
| `reapply-services.sh` | Added all 4 new services to ALL_SERVICES array + restart cases |
| `opencode/opencode.json.tlp` | Added `llama-35b-mxfp4-mtp` and `llama-35b-nvfp4` provider entries with model definitions |

## Usage

### Setup

```bash
# MXFP4-MTP only (recommended — has MTP speculative decoding)
sudo bash llama/setup-mtp.sh --model 35b-mxfp4

# NVFP4 only (no MTP, slightly smaller at ~21GB)
sudo bash llama/setup-mtp.sh --model 35b-nvfp4

# All models including new ones
sudo bash llama/setup-mtp.sh --all

# Rebuild llama.cpp only, skip model downloads
sudo bash llama/setup-mtp.sh --model 35b-mxfp4 --update

# Test mode (installs to /opt/llama-mtp-test/, port 10502)
sudo bash llama/setup-mtp.sh --model 35b-mxfp4 --test
```

### Service Switching

```bash
# MXFP4-MTP variants
./scripts/service-switcher.sh 35b-mxfp4-mtp        # 64K context, spec decode n=6
./scripts/service-switcher.sh 35b-mxfp4-mtp-131k   # 131K context, spec decode n=6

# NVFP4 variants (no MTP)
./scripts/service-switcher.sh 35b-nvfp4            # 64K context
./scripts/service-switcher.sh 35b-nvfp4-131k       # 131K context

# Stop all inference servers
./scripts/service-switcher.sh stop
```

### Reapply Services (after username/path changes)

```bash
sudo ./scripts/reapply-services.sh 35b-mxfp4-mtp    # Rebuild + restart specific service
sudo ./scripts/reapply-services.sh                  # Rebuild all services
```

## Service Configuration Details

### MXFP4-MTP Services

| Parameter | 64K | 131K |
|-----------|-----|------|
| Model path | `/opt/models-mtp/qwen3.6-35b-a3b-mxfp4-mtp/Qwen3.6-35B-A3B-MXFP4_MOE.gguf` | same |
| Context (`-c`) | 65536 | 131072 |
| Output (`-n`) | 8192 | 16384 |
| Fit threshold (`-fitt`) | 2048 | 8192 |
| Spec type | `--spec-type draft-mtp` | same |
| Spec drafts | `--spec-draft-n-max 6` | same |
| KV cache type | q4_1 | bf16 (for larger context) |
| MemoryMax | 24G | 28G |

### NVFP4 Services

| Parameter | 64K | 131K |
|-----------|-----|------|
| Model path | `/opt/models-mtp/qwen3.6-35b-a3b-nvfp4/Qwen3.6-35B-A3B-NVFP4.gguf` | same |
| Context (`-c`) | 65536 | 131072 |
| Output (`-n`) | 8192 | 16384 |
| Fit threshold (`-fitt`) | 2048 | 8192 |
| Spec type | (none) | (none) |
| KV cache type | q4_1 | bf16 |
| MemoryMax | 24G | 28G |

## OpenCode Configuration

Add to `~/.config/opencode/opencode.json`:

```json
"llama-35b-mxfp4-mtp": {
  "npm": "@ai-sdk/openai-compatible",
  "name": "llama.cpp | Qwen3.6-35B A3B MXFP4-MTP (Blackwell FP4, spec decode n=6)",
  "options": {
    "baseURL": "http://localhost:10500/v1"
  },
  "models": {
    "qwen3.6-35b-a3b-mxfp4-mtp": {
      "name": "Qwen3.6-35B A3B MXFP4-MTP (131K, spec decode)",
      "limit": { "context": 131072, "output": 16384 }
    },
    "qwen3.6-35b-a3b-mxfp4-mtp-64k": {
      "name": "Qwen3.6-35B A3B MXFP4-MTP (64K, spec decode)",
      "limit": { "context": 65536, "output": 8192 }
    }
  }
},
"llama-35b-nvfp4": {
  "npm": "@ai-sdk/openai-compatible",
  "name": "llama.cpp | Qwen3.6-35B A3B NVFP4 (Blackwell FP4, no MTP)",
  "options": {
    "baseURL": "http://localhost:10500/v1"
  },
  "models": {
    "qwen3.6-35b-a3b-nvfp4": {
      "name": "Qwen3.6-35B A3B NVFP4 (131K)",
      "limit": { "context": 131072, "output": 16384 }
    },
    "qwen3.6-35b-a3b-nvfp4-64k": {
      "name": "Qwen3.6-35B A3B NVFP4 (64K)",
      "limit": { "context": 65536, "output": 8192 }
    }
  }
}
```

## Why Not True NVFP4+MTP?

The RedHatAI `Qwen3.6-35B-A3B-NVFP4` checkpoint preserves the MTP draft head in a separate `model_mtp.safetensors` file for **vLLM** use (via `compressed-tensors`). Converting this to GGUF format for llama.cpp would require merging the draft head tensors into the GGUF — no tooling exists for that yet.

The knoopx NVFP4 GGUF conversion uses standard GGUF quantization and doesn't include MTP layers.

**MXFP4 is the practical answer**: same Blackwell SM120 tensor core instructions, llama.cpp-native FP4 packing, and full MTP draft head support via unsloth's GGUF conversion pipeline.
