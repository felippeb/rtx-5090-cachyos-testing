#!/usr/bin/env bash
set -euo pipefail

# Tauri Coding Benchmark: Model x Client Matrix Runner
# Usage: ./benchmark-tauri.sh [model] [client] [--matrix] [--dry-run] [--no-verify]
# Models: 27b-mtp, 35b-mtp, gemma4-mtp, gemma4-turbo
# Clients: curl, opencode, hermes, pi
# --matrix: Run all clients against the selected model
# --dry-run: Show commands without executing
# --no-verify: Skip the build verification step

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SWITCHER="$ROOT_DIR/scripts/service-switcher.sh"
OUTPUT_DIR="$SCRIPT_DIR/benchmark-output-$(date +%Y%m%d-%H%M%S)"
PORT=10500
PROMPT_FILE_BASE="$ROOT_DIR/docs/tauri-challenge-spec-base.md"
PROMPT_FILE_MCP="$ROOT_DIR/docs/tauri-challenge-spec.md"

# Select prompt file based on client
select_prompt_file() {
    local client="$1"
    case "$client" in
        curl)
            # curl = raw LLM call, no MCP/tools. Use base spec.
            echo "$PROMPT_FILE_BASE"
            ;;
        opencode|hermes|pi)
            # These clients have MCP/tool ecosystems. Use MCP-enabled spec.
            echo "$PROMPT_FILE_MCP"
            ;;
        *)
            echo "$PROMPT_FILE_BASE"
            ;;
    esac
}
SWITCH_MODEL="${SWITCH_MODEL:-true}"
DRY_RUN="${DRY_RUN:-false}"
VERIFY_BUILD="${VERIFY_BUILD:-true}"

# Model -> service-switcher mode mapping
declare -A MODE_MAP=(
    ["27b-mtp"]="unsloth-mtp"
    ["35b-mtp"]="unsloth-35b-mtp"
    ["gemma4-mtp"]="gemma4-mtp"
    ["gemma4-turbo"]="gemma4-turbo"
)

# Argument parsing
REAL_MODE=""
CLIENT=""
MATRIX=false
DRY_RUN=false
HELP=false
VERIFY_BUILD=true

for arg in "$@"; do
    case "$arg" in
        --help)      HELP=true ;;
        --matrix)    MATRIX=true ;;
        --dry-run)   DRY_RUN=true ;;
        --no-switch) SWITCH_MODEL=false ;;
        --no-verify) VERIFY_BUILD=false ;;
        *)
            if [[ -z "$REAL_MODE" ]]; then
                REAL_MODE="$arg"
            elif [[ -z "$CLIENT" ]]; then
                CLIENT="$arg"
            fi
            ;;
    esac
done

# Apply defaults
[[ -z "$REAL_MODE" ]] && REAL_MODE="35b-mtp"
[[ -z "$CLIENT" ]] && CLIENT="curl"

if [[ "$HELP" == "true" ]]; then
    echo "Usage: ./benchmark-tauri.sh [model] [client] [flags]"
    echo ""
    echo "Models: 27b-mtp, 35b-mtp, gemma4-mtp, gemma4-turbo"
    echo "Clients: curl, opencode, hermes, pi"
    echo ""
    echo "Flags:"
    echo "  --matrix    Run all clients against the selected model"
    echo "  --dry-run   Show commands without executing"
    echo "  --no-switch Skip model switching (use currently active server)"
    echo "  --no-verify Skip build verification step"
    echo "  --help      Show this help message"
    echo ""
    echo "Examples:"
    echo "  ./benchmark-tauri.sh 35b-mtp curl          # Single test"
    echo "  ./benchmark-tauri.sh 35b-mtp --matrix      # Test all clients"
    echo "  ./benchmark-tauri.sh 35b-mtp --dry-run     # Preview commands"
    exit 0
fi

REAL_MODE="${MODE_MAP[$REAL_MODE]:-$REAL_MODE}"

# ─────────────────────────────────────────────────────────────
# ENERGY / POWER ESTIMATION
# RTX 5090: ~575W TDP, idle ~30W, ~330 tok/s with MTP
# ─────────────────────────────────────────────────────────────
GPU_TDP_WATTS=575
GPU_IDLE_WATTS=30
GPU_ACTIVE_WATTS=250        # estimated sustained draw during MTP inference
PROMPT_TOKENS_ESTIMATE=50   # rough estimate for our prompt
TOKEN_RATE_TOKS_PER_SEC=330 # measured from smoke tests

estimate_energy() {
    local elapsed_ms="$1"
    local output_tokens="$2"
    local prompt_tokens="$3"

    python3 -c "
import math
elapsed_s = $elapsed_ms / 1000.0
output_tokens = $output_tokens
prompt_tokens = $prompt_tokens

gpu_watts = $GPU_ACTIVE_WATTS
idle_watts = $GPU_IDLE_WATTS

# Prompt phase (very fast, ~30ms)
prompt_s = 0.03
prompt_energy_wh = idle_watts * prompt_s / 1000.0

# Generation phase
gen_s = max(0, elapsed_s - prompt_s)
gen_energy_wh = gpu_watts * gen_s / 1000.0

total_energy_wh = prompt_energy_wh + gen_energy_wh
total_tokens = prompt_tokens + output_tokens

print(f'{total_energy_wh:.2f}Wh')
print(f'{total_tokens} tokens ({prompt_tokens} prompt + {output_tokens} output)')
print(f'{total_energy_wh / max(1, total_tokens) * 1000:.3f}Wh per 1000 tokens')
print(f'{gen_s:.1f}s generation, {total_s:.1f}s total')
" 2>/dev/null || echo "energy estimate unavailable"
}

# ─────────────────────────────────────────────────────────────
# BUILD VERIFICATION
# ─────────────────────────────────────────────────────────────
_verify_build() {
    local client_dir="$1"
    local client="$2"
    local elapsed_ms="$3"
    local output_tokens="$4"
    local prompt_tokens="$5"

    echo ""
    echo "  Verifying build..."

    # Find the project root (the directory containing package.json or Cargo.toml)
    local project_root=""
    if [[ -f "$client_dir/package.json" && -f "$client_dir/Cargo.toml" ]]; then
        project_root="$client_dir"
    else
        # Look for a subdirectory that has both
        project_root=$(find "$client_dir" -maxdepth 2 -name "package.json" -exec dirname {} \; 2>/dev/null | head -1)
    fi

    if [[ -z "$project_root" ]]; then
        echo "  SKIP: No project root found (no package.json + Cargo.toml)"
        return 1
    fi

    echo "  Project root: $project_root"

    # Check for required files
    local missing=0
    local required=("package.json" "Cargo.toml" "src-tauri" "src")
    for req in "${required[@]}"; do
        if [[ ! -d "$project_root/$req" && ! -f "$project_root/$req" ]]; then
            echo "  MISSING: $req"
            missing=$((missing + 1))
        fi
    done

    if (( missing > 0 )); then
        echo "  SKIP: $missing required files missing"
        return 1
    fi

    echo "  File structure looks complete."

    # Try npm install (user-space, will fail gracefully if node/npm missing)
    echo "  Running npm install..."
    local npm_ok=false
    if command -v npm &>/dev/null; then
        (cd "$project_root" && npm install --prefer-offline 2>&1 | tail -3) || {
            echo "  npm install failed (may need node.js)"
        }
        npm_ok=true
    else
        echo "  SKIP: npm not found"
    fi

    # Try cargo check (user-space, will fail gracefully if rust/cargo missing)
    echo "  Running cargo check..."
    local cargo_ok=false
    if command -v cargo &>/dev/null; then
        (cd "$project_root" && cargo check 2>&1 | tail -5) || {
            echo "  cargo check failed (may need rust toolchain or Tauri deps)"
        }
        cargo_ok=true
    else
        echo "  SKIP: cargo not found"
    fi

    # Write verification result
    local verify_json="$client_dir/verification.json"
    python3 -c "
import json
result = {
    'project_root': '$project_root',
    'npm_ok': $npm_ok,
    'cargo_ok': $cargo_ok,
    'build_status': 'partial' if ($npm_ok or $cargo_ok) else 'skipped',
    'missing_files': $missing
}
with open('$verify_json', 'w') as f:
    json.dump(result, f, indent=2)
print(json.dumps(result, indent=2))
" 2>/dev/null || echo "  Verification JSON write failed"
}

# ─────────────────────────────────────────────────────────────
# LOGGING
# ─────────────────────────────────────────────────────────────
_write_log_entry() {
    local log_file="$1"
    local client="$2"
    local model="$3"
    local elapsed_ms="$4"
    local file_count="$5"
    local resp_size="$6"
    local prompt_tokens="$7"
    local output_tokens="$8"
    local energy_wh="$9"
    local build_status="${10}"

    python3 -c "
import json, datetime
entry = {
    'timestamp': datetime.datetime.now().isoformat(),
    'model': '$model',
    'client': '$client',
    'elapsed_ms': $elapsed_ms,
    'elapsed_s': round($elapsed_ms / 1000.0, 2),
    'files_extracted': $file_count,
    'response_bytes': $resp_size,
    'prompt_tokens': $prompt_tokens,
    'output_tokens': $output_tokens,
    'energy_wh': '$energy_wh',
    'build_status': '$build_status',
    'token_rate': round($output_tokens / max(0.1, ($elapsed_ms - 30) / 1000.0), 1) if $output_tokens > 0 else 0
}
with open('$log_file', 'a') as f:
    f.write(json.dumps(entry) + '\n')
"
}

# ─────────────────────────────────────────────────────────────
# BUILD CLIENT SCRIPT
# ─────────────────────────────────────────────────────────────
_build_script() {
    local client="$1"
    local model="$2"
    local prompt_file="$3"
    local port="$4"

    case "$client" in
        curl)
            cat <<EOF
python3 -c "
import json, sys
payload = {
    'model': '$model',
    'messages': [{'role': 'user', 'content': open('$prompt_file').read()}],
    'temperature': 0.1,
    'max_tokens': 16384,
    'stream': False
}
print(json.dumps(payload))
" '$model' '$prompt_file' | curl -s -X POST "http://localhost:$port/v1/chat/completions" -H "Content-Type: application/json" -d @-
EOF
            ;;
        opencode)
            local op_provider="llama-mtp-35b"
            local op_model="qwen3.6-35b-a3b-mtp-131k"
            case "$model" in
                unsloth-mtp)       op_provider="llama-mtp-27b"; op_model="qwen3.6-27b-mtp-131k" ;;
                unsloth-35b-mtp)   op_provider="llama-mtp-35b"; op_model="qwen3.6-35b-a3b-mtp-131k" ;;
                gemma4-mtp)        op_provider="gemma4-mtp";    op_model="gemma4-31b-mtp-131k" ;;
                gemma4-turbo)      op_provider="gemma4-turbo";  op_model="gemma4-31b-mtp-131k" ;;
            esac
            cat <<EOF
opencode run "\$(cat '$prompt_file')" --model "$op_provider/$op_model" --format json 2>&1
EOF
            ;;
        hermes)
            cat <<EOF
hermes chat -q "\$(cat '$prompt_file')" -Q -m "$model"
EOF
            ;;
        pi)
            cat <<EOF
pi --print --provider llama-local --model "$model" "@$prompt_file"
EOF
            ;;
    esac
}

# ─────────────────────────────────────────────────────────────
# RUN A SINGLE CLIENT BENCHMARK
# ─────────────────────────────────────────────────────────────
_run_client() {
    local model="$1"
    local client="$2"
    local out_dir="$3"
    local client_dir="$out_dir/$client"
    mkdir -p "$client_dir"

    # Select prompt file based on client
    local prompt_file
    prompt_file=$(select_prompt_file "$client")

    # Write command to a temp script
    local SCRIPT_FILE
    SCRIPT_FILE=$(mktemp)
    _build_script "$client" "$model" "$prompt_file" "$PORT" > "$SCRIPT_FILE"

    local RESPONSE_FILE="$client_dir/response.json"
    local START_NS
    START_NS=$(date +%s%N)

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "  [DRY-RUN] Would execute:"
        cat "$SCRIPT_FILE"
        echo "    -> $RESPONSE_FILE"
        rm -f "$SCRIPT_FILE"
        return 0
    fi

    echo "  Executing: $client (from $client_dir)..."
    (cd "$client_dir" && bash "$SCRIPT_FILE") > "$RESPONSE_FILE" 2>&1 || {
        echo "  ERROR: $client failed. Check: $RESPONSE_FILE"
        rm -f "$SCRIPT_FILE"
        return 1
    }
    rm -f "$SCRIPT_FILE"

    local END_NS
    END_NS=$(date +%s%N)
    local ELAPSED_MS=$(( (END_NS - START_NS) / 1000000 ))
    echo "  Response captured in ${ELAPSED_MS}ms"

    # ── EXTRACT FILES ──
    echo "  Extracting files..."
    local EXTRACT_OUTPUT
    EXTRACT_OUTPUT=$(python3 - "$RESPONSE_FILE" "$client_dir" <<'PYEOF'
import json, sys, os, re

resp_file = sys.argv[1]
out_dir = sys.argv[2]

try:
    with open(resp_file, 'r') as f:
        raw = f.read()
    # Check if this is opencode NDJSON format (lines starting with {)
    lines = raw.strip().split('\n')
    is_ndjson = len(lines) > 1 and all(l.strip().startswith('{') for l in lines[:5] if l.strip())
    if is_ndjson:
        # opencode format: extract text from type:"text" events AND write tool calls
        text_parts = []
        write_files = []  # (relative_path, content) from write tool calls
        total_tokens = {'input': 0, 'output': 0, 'reasoning': 0}
        # Find the common prefix to strip from write tool filePaths
        all_file_paths = []
        for line in lines:
            try:
                d = json.loads(line.strip())
                part = d.get('part', {})
                if part.get('type') == 'tool' and part.get('tool') == 'write':
                    inp = part.get('state', {}).get('input', {})
                    fp = inp.get('filePath', '')
                    if fp:
                        all_file_paths.append(fp)
            except:
                pass
        # Compute common prefix
        common_prefix = os.path.commonpath(all_file_paths) if all_file_paths else ''
        if common_prefix and not common_prefix.endswith('/'):
            common_prefix += '/'
        for line in lines:
            try:
                d = json.loads(line.strip())
                if d.get('type') == 'text':
                    text_parts.append(d.get('part', {}).get('text', ''))
                if d.get('type') == 'step_finish':
                    tokens = d.get('part', {}).get('tokens', {})
                    total_tokens['input'] += tokens.get('input', 0)
                    total_tokens['output'] += tokens.get('output', 0)
                    total_tokens['reasoning'] += tokens.get('reasoning', 0)
                part = d.get('part', {})
                if part.get('type') == 'tool' and part.get('tool') == 'write':
                    inp = part.get('state', {}).get('input', {})
                    fp = inp.get('filePath', '')
                    fc = inp.get('content', '')
                    if fp and fc:
                        # Strip common prefix to get relative path
                        rel = fp[len(common_prefix):] if fp.startswith(common_prefix) else os.path.basename(fp)
                        write_files.append((rel, fc))
            except:
                pass
        content = '\n\n'.join(text_parts)
        # Write token counts for the caller
        with open(os.path.join(out_dir, 'opencode_tokens.json'), 'w') as f:
            json.dump(total_tokens, f)
        # Save files from write tool calls
        os.makedirs(out_dir, exist_ok=True)
        for rel_path, fc in write_files:
            fpath = os.path.join(out_dir, rel_path)
            os.makedirs(os.path.dirname(fpath) or '.', exist_ok=True)
            with open(fpath, 'w') as f:
                f.write(fc)
            print(f"  Saved: {rel_path} ({len(fc)} chars)")
        # Skip the generic extraction below since we already saved files
        sys.exit(0)
    else:
        data = json.loads(raw)
        msg = data.get('choices', [{}])[0].get('message', {})
        reasoning = msg.get('reasoning_content', '')
        actual_content = msg.get('content', '')
        if reasoning and not actual_content:
            content = reasoning
        elif actual_content and not reasoning:
            content = actual_content
        else:
            content = reasoning + '\n\n' + actual_content
except Exception as e:
    with open(resp_file, 'r') as f:
        content = f.read()

# Strip common MCP/client wrapper patterns
content = re.sub(r'\{.*?"tool_calls".*\}', '', content, flags=re.DOTALL)

# Try format 1: --- filename: path --- separators
pattern = r'---\s*(?:filename:\s*)?(.+?)\s*---\s*\n(.*?)(?=---\s*(?:filename:\s*)?(?:.+?)\s*---|\Z)'
matches = re.findall(pattern, content, re.DOTALL)

# If no matches, try to extract from markdown code blocks (before stripping)
if not matches:
    code_pattern = r'```(\w*)\n(.*?)```'
    code_blocks = re.findall(code_pattern, content, re.DOTALL)
    if code_blocks:
        lang_to_ext = {
            'rust': '.rs', 'typescript': '.ts', 'tsx': '.tsx',
            'json': '.json', 'toml': '.toml', 'javascript': '.js',
            'jsx': '.jsx', 'css': '.css', 'html': '.html', 'sql': '.sql',
            'bash': '.sh', 'shell': '.sh', 'python': '.py', 'md': '.md',
        }
        for i, (lang, block_content) in enumerate(code_blocks):
            ext = lang_to_ext.get(lang, '.txt')
            fname = f"generated_file_{i}{ext}"
            matches.append((fname, block_content))

# Now strip code blocks (they're already extracted above)
content = re.sub(r'```(?:json|text)?\n(.*?)```', r'\1', content, flags=re.DOTALL)

os.makedirs(out_dir, exist_ok=True)
seen = {}
for raw_path, fcontent in matches:
    raw_path = raw_path.strip()
    fname = raw_path.replace('\\', '/')
    fname = re.sub(r'[<>:"|?*]', '_', fname)
    if not fname.endswith(('.rs', '.ts', '.tsx', '.js', '.jsx', '.json', '.toml', '.css', '.html', '.sql', '.md')):
        fname += ".txt"
    dir_part = os.path.dirname(fname)
    base, ext = os.path.splitext(os.path.basename(fname))
    counter = 1
    full_name = fname
    while full_name in seen:
        counter += 1
        full_name = os.path.join(dir_part, f"{base}_{counter}{ext}") if dir_part else f"{base}_{counter}{ext}"
    seen[full_name] = True
    fpath = os.path.join(out_dir, full_name)
    os.makedirs(os.path.dirname(fpath) or '.', exist_ok=True)
    with open(fpath, 'w') as f:
        f.write(fcontent.strip())
    print(f"  Saved: {full_name} ({len(fcontent)} chars)")

print(f"  Total files extracted: {len(matches)}")
PYEOF
    )
    echo "$EXTRACT_OUTPUT"

    # ── PARSE TOKEN COUNTS FROM RESPONSE ──
    local prompt_tokens=0
    local output_tokens=0

    # Check for opencode NDJSON token counts (written by extraction step)
    if [[ -f "$client_dir/opencode_tokens.json" ]]; then
        prompt_tokens=$(python3 -c "import json; d=json.load(open('$client_dir/opencode_tokens.json')); print(d.get('input', 0))" 2>/dev/null || echo 0)
        output_tokens=$(python3 -c "import json; d=json.load(open('$client_dir/opencode_tokens.json')); print(d.get('output', 0))" 2>/dev/null || echo 0)
    else
        local timing_json
        timing_json=$(python3 -c "
import json
try:
    d = json.load(open('$RESPONSE_FILE'))
    timings = d.get('timings', {})
    usage = d.get('usage', {})
    print(json.dumps({'prompt': usage.get('prompt_tokens', 0), 'output': usage.get('completion_tokens', 0), 'timings': timings}))
except:
    print('{}')
" 2>/dev/null || echo "{}")

        prompt_tokens=$(echo "$timing_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('prompt', 0))" 2>/dev/null || echo 0)
        output_tokens=$(echo "$timing_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('output', 0))" 2>/dev/null || echo 0)
    fi

    # ── ESTIMATE ENERGY ──
    local energy_wh="N/A"
    if (( output_tokens > 0 )); then
        energy_wh=$(estimate_energy "$ELAPSED_MS" "$output_tokens" "$prompt_tokens" | head -1)
    fi

    # ── VERIFY BUILD ──
    local build_status="skipped"
    if [[ "$VERIFY_BUILD" == "true" ]]; then
        _verify_build "$client_dir" "$client" "$ELAPSED_MS" "$output_tokens" "$prompt_tokens" || true
        # Read build status from verification JSON
        if [[ -f "$client_dir/verification.json" ]]; then
            build_status=$(python3 -c "import json; print(json.load(open('$client_dir/verification.json')).get('build_status', 'unknown'))" 2>/dev/null || echo "unknown")
        fi
    fi

    # ── SUMMARY ──
    local file_count
    file_count=$(ls -1 "$client_dir" 2>/dev/null | wc -l)
    local resp_size
    resp_size=$(wc -c < "$RESPONSE_FILE" 2>/dev/null || echo 0)

    echo ""
    echo "  ════════════════════════════════════════════"
    echo "  Client:  $client"
    echo "  Time:    ${ELAPSED_MS}ms ($(echo "scale=1; $ELAPSED_MS/1000" | bc 2>/dev/null || echo "$((ELAPSED_MS / 1000))")s)"
    echo "  Tokens:  prompt=$prompt_tokens  output=$output_tokens"
    echo "  Energy:  ~$energy_wh"
    echo "  Files:   $file_count extracted"
    echo "  Build:   $build_status"
    echo "  ════════════════════════════════════════════"

    # ── WRITE LOG ENTRY ──
    local log_file="$out_dir/benchmark-log.jsonl"
    _write_log_entry "$log_file" "$client" "$model" "$ELAPSED_MS" "$file_count" "$resp_size" "$prompt_tokens" "$output_tokens" "$energy_wh" "$build_status"
}

# ─────────────────────────────────────────────────────────────
# MAIN LOGIC
# ─────────────────────────────────────────────────────────────
mkdir -p "$OUTPUT_DIR"

echo "=== Tauri Coding Benchmark (Model x Client Matrix) ==="
echo "Model: $REAL_MODE"
echo "Client: $CLIENT"
echo "Output: $OUTPUT_DIR"
echo "Server: http://localhost:$PORT"
echo "--------------------------------"

# 1. Switch model (optional, requires sudo)
if [[ "$SWITCH_MODEL" == "true" ]]; then
    echo "[1/7] Switching to $REAL_MODE..."
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "  [DRY-RUN] Would execute: sudo $SWITCHER $REAL_MODE"
    else
        sudo "$SWITCHER" "$REAL_MODE"
        sleep 15
    fi
else
    echo "[1/7] Skipping model switch (using currently active server)"
fi

# 2. Wait for server readiness
echo "[2/7] Waiting for server on port $PORT..."
START_WAIT=$(date +%s)
while true; do
    if curl -s "http://localhost:$PORT/health" > /dev/null 2>&1 || \
       curl -s "http://localhost:$PORT/v1/models" > /dev/null 2>&1; then
        echo "  Server ready."
        break
    fi
    ELAPSED=$(( $(date +%s) - START_WAIT ))
    if (( ELAPSED > 120 )); then
        echo "  ERROR: Server did not start within 120s"
        exit 1
    fi
    sleep 2
done

# 3. Check prompt file
PROMPT_FILE=$(select_prompt_file "$CLIENT")
echo "Prompt file: $PROMPT_FILE"
if [[ ! -f "$PROMPT_FILE" ]]; then
    echo "ERROR: $PROMPT_FILE not found."
    exit 1
fi

# 4. Run benchmark
if [[ "$MATRIX" == "true" ]]; then
    echo "[3/7] Running MATRIX mode (all clients)..."
    for c in curl opencode hermes pi; do
        echo ""
        echo "  >>> $c <<<"
        _run_client "$REAL_MODE" "$c" "$OUTPUT_DIR"
    done
else
    echo "[3/7] Running single client: $CLIENT"
    _run_client "$REAL_MODE" "$CLIENT" "$OUTPUT_DIR"
fi

# 5. Print consolidated log
echo ""
echo "================================"
echo "Benchmark complete."
echo "Results saved in: $OUTPUT_DIR"
if [[ -f "$OUTPUT_DIR/benchmark-log.jsonl" ]]; then
    echo ""
    echo "Consolidated log: $OUTPUT_DIR/benchmark-log.jsonl"
    echo "Contents:"
    cat "$OUTPUT_DIR/benchmark-log.jsonl" | python3 -c "
import json, sys
for line in sys.stdin:
    d = json.loads(line.strip())
    print(f\"  {d['client']:8s} | {d['elapsed_s']:6.1f}s | {d['output_tokens']:5d} tokens | ~{d['energy_wh']:>6s} | build={d['build_status']}\")
" 2>/dev/null || true
fi
echo ""
echo "Run again: ./benchmark-tauri.sh <model> <client> [--matrix]"
