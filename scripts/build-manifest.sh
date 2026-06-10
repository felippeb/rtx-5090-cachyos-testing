#!/usr/bin/env bash
# Build manifest — captures full reproducibility metadata.
# Usage: ./scripts/build-manifest.sh [--out path]
# Output: build-manifest.json in repo root (or specified path)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:--}"
if [[ "$OUT" == "--out" ]]; then shift; fi
OUT_FILE="${1:-$SCRIPT_DIR/build-manifest.json}"

# ─── Git info ──────────────────────────────────────────────────────
git_commit=$(git -C "$SCRIPT_DIR" rev-parse HEAD 2>/dev/null || echo "unknown")
git_branch=$(git -C "$SCRIPT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
git_dirty=$(git -C "$SCRIPT_DIR" diff --quiet 2>/dev/null && echo "false" || echo "true")
git_timestamp=$(git -C "$SCRIPT_DIR" log -1 --format='%ci' 2>/dev/null || echo "unknown")

# ─── System info ───────────────────────────────────────────────────
kernel=$(uname -r)
os_name=$(uname -o)
hostname=$(uname -n)
python_ver=$(python3 --version 2>/dev/null || echo "N/A")

# ─── GPU / Driver ──────────────────────────────────────────────────
gpu_name=$(nvidia-smi --query-gpu=name --format=csv,noheader,nounits 2>/dev/null || echo "N/A")
driver_version=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader,nounits 2>/dev/null || echo "N/A")
cuda_driver=$(nvidia-smi --query-gpu=cuda_version --format=csv,noheader,nounits 2>/dev/null || echo "N/A")
gpu_mem_total=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null || echo "N/A")

# ─── Docker images ─────────────────────────────────────────────────
llama_image_sha=$(docker inspect --format='{{id}}' rtx-inference_llama 2>/dev/null | head -c 16 || echo "not-built")

# ─── Chat template hash ────────────────────────────────────────────
template_file="$SCRIPT_DIR/docker/chat_template.jinja"
template_hash=$(sha256sum "$template_file" 2>/dev/null | cut -c1-64 || echo "missing")
template_lines=$(wc -l < "$template_file" 2>/dev/null || echo "0")

# ─── Model registry stats ──────────────────────────────────────────
models_yaml="$SCRIPT_DIR/config/models.yaml"
model_count=$(grep -c '^  [a-z].*:$' "$models_yaml" 2>/dev/null || echo "0")

# ─── Compose services count ────────────────────────────────────────
compose_file="$SCRIPT_DIR/docker/docker-compose.yml"
service_count=$(grep -c '^  [a-zA-Z].*:' "$compose_file" 2>/dev/null || echo "0")

# ─── Timestamp ─────────────────────────────────────────────────────
timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# ─── Write JSON ────────────────────────────────────────────────────
python3 -c "
import json, sys

data = {
    'generated_at': '$timestamp',
    'git': {
        'commit': '$git_commit',
        'branch': '$git_branch',
        'dirty': $([ '$git_dirty' = 'true' ] && echo 'True' || echo 'False'),
        'timestamp': '$git_timestamp',
    },
    'system': {
        'kernel': '$kernel',
        'os': '$os_name',
        'hostname': '$hostname',
        'python': '$python_ver',
    },
    'gpu': {
        'name': '$gpu_name',
        'driver_version': '$driver_version',
        'cuda_version': '$cuda_driver',
        'memory_total_mib': '$gpu_mem_total',
    },
    'chat_template': {
        'file': 'docker/chat_template.jinja',
        'sha256': '$template_hash',
        'lines': int('$template_lines'),
        'version': 'v1.2.0',
    },
    'registry': {
        'model_count': int('$model_count'),
        'compose_service_count': int('$service_count'),
    },
}

print(json.dumps(data, indent=2))
" > "$OUT_FILE"

echo "Build manifest written to: $OUT_FILE"
