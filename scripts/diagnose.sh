#!/usr/bin/env bash
# Runtime diagnostics — outputs system + inference state for debugging.
# Usage: ./scripts/diagnose.sh [--json]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_DIR="$SCRIPT_DIR/config"
OUTPUT_JSON="${1:-}"

as_json=false
if [[ "$OUTPUT_JSON" == "--json" ]]; then
    as_json=true
fi

# ─── Helpers ──────────────────────────────────────────────────────
section() {
    if $as_json; then return; fi
    echo ""
    echo "═══ $1 ═══"
}

# ─── GPU Info ─────────────────────────────────────────────────────
section "GPU Hardware"
gpu_name=$(nvidia-smi --query-gpu=name --format=csv,noheader,nounits 2>/dev/null || echo "N/A")
gpu_mem_total=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null || echo "N/A")
gpu_mem_used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null || echo "N/A")
gpu_power=$(nvidia-smi --query-gpu=power.draw --format=csv,noheader,nounits 2>/dev/null || echo "N/A")
gpu_temp=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null || echo "N/A")
gpu_util=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null || echo "N/A")

if $as_json; then
    gpu_json="{\"name\":\"$gpu_name\",\"memory_total_mb\":$gpu_mem_total,\"memory_used_mb\":$gpu_mem_used,\"power_w\":$gpu_power,\"temp_c\":$gpu_temp,\"utilization_pct\":$gpu_util}"
else
    echo "  Model:      $gpu_name"
    echo "  VRAM Total: ${gpu_mem_total} MiB"
    echo "  VRAM Used:  ${gpu_mem_used} MiB"
    echo "  Power:      ${gpu_power} W"
    echo "  Temperature: ${gpu_temp} °C"
    echo "  GPU Util:   ${gpu_util} %"
fi

# ─── Driver / CUDA ────────────────────────────────────────────────
section "Driver & CUDA"
driver_version=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader,nounits 2>/dev/null || echo "N/A")
cuda_version=$(nvcc --version 2>/dev/null | grep -oP 'release \K[0-9.]+' || echo "N/A (host)")

if $as_json; then
    driver_json="{\"driver_version\":\"$driver_version\",\"cuda_version\":\"$cuda_version\"}"
else
    echo "  Driver:     $driver_version"
    echo "  CUDA (host): $cuda_version"
fi

# ─── OS / Kernel ──────────────────────────────────────────────────
section "System"
kernel=$(uname -r)
hostname=$(uname -n)
uptime=$(uptime -p 2>/dev/null || uptime)
python_ver=$(python3 --version 2>/dev/null || echo "N/A")

if $as_json; then
    sys_json="{\"kernel\":\"$kernel\",\"hostname\":\"$hostname\",\"python\":\"$python_ver\"}"
else
    echo "  Kernel:     $kernel"
    echo "  Hostname:   $hostname"
    echo "  Uptime:     $uptime"
    echo "  Python:     $python_ver"
fi

# ─── Docker Services ──────────────────────────────────────────────
section "Docker Services"
running=$($SCRIPT_DIR/docker/../docker compose --project-name rtx-inference ps --format json 2>/dev/null | python3 -c "
import json, sys
try:
    containers = [json.loads(l) for l in sys.stdin if l.strip()]
    for c in containers:
        name = c.get('Service', c.get('Name', '?'))
        state = c.get('State', '?')
        print(f'  {name}: {state}')
except:
    print('  (unable to parse)')
" 2>/dev/null || echo "  (docker compose unavailable)")

if $as_json; then
    services_json="[]"
else
    echo "$running"
fi

# ─── Active Model (from registry) ────────────────────────────────
section "Model Registry"
model_count=$(grep -c '^  [a-z]' "$CONFIG_DIR/models.yaml" 2>/dev/null || echo "0")
if $as_json; then
    registry_json="{\"registered_models\":$model_count}"
else
    echo "  Registered models: $model_count"
fi

# ─── Chat Template Version ────────────────────────────────────────
section "Chat Template"
template_file="$SCRIPT_DIR/docker/chat_template.jinja"
if [[ -f "$template_file" ]]; then
    template_hash=$(sha256sum "$template_file" | cut -c1-16)
    template_lines=$(wc -l < "$template_file")
    if $as_json; then
        template_json="{\"file\":\"$template_file\",\"hash\":\"$template_hash\",\"lines\":$template_lines}"
    else
        echo "  File:       $template_file"
        echo "  SHA256:     ${template_hash}..."
        echo "  Lines:      $template_lines"
    fi
else
    if $as_json; then
        template_json="{\"error\":\"not found\"}"
    else
        echo "  Not found"
    fi
fi

# ─── llama.cpp version (from running container or build) ──────────
section "llama.cpp"
llama_version=$(docker run --rm --entrypoint "" ghcr.io/ggml-org/llama.cpp:latest llama-server --version 2>/dev/null | head -1 || echo "N/A (check Dockerfile)")
if $as_json; then
    llama_json="{\"version\":\"$llama_version\"}"
else
    echo "  Version:    $llama_version"
fi

# ─── Output JSON or exit ──────────────────────────────────────────
if $as_json; then
    python3 -c "
import json, sys
data = {
    'gpu': $gpu_json,
    'driver': $driver_json,
    'system': $sys_json,
    'registry': $registry_json,
    'chat_template': $template_json,
}
print(json.dumps(data, indent=2))
"
fi
