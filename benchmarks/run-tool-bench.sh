#!/usr/bin/env bash
# Run tool-eval-bench against a local llama-server instance
# Usage: ./run-tool-bench.sh [--short] [--port PORT] [--seed SEED]
#
# Examples:
#   ./run-tool-bench.sh                    # Full 69-scenario benchmark on port 10500
#   ./run-tool-bench.sh --short            # Quick 15-scenario benchmark
#   ./run-tool-bench.sh --port 10503       # Test a different server port
#   ./run-tool-bench.sh --short --seed 123 # Quick run with different seed

set -euo pipefail

PORT=10500
SEED=42
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --short)
            EXTRA_ARGS+=("--short")
            shift
            ;;
        --port)
            PORT="$2"
            shift 2
            ;;
        --seed)
            SEED="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--short] [--port PORT] [--seed SEED]"
            exit 1
            ;;
    esac
done

BASE_URL="http://localhost:${PORT}"

# Check server is alive
echo "Checking server at ${BASE_URL}..."
if ! curl -sf "${BASE_URL}/health" >/dev/null 2>&1; then
    echo "ERROR: Server not responding at ${BASE_URL}"
    echo "Start a llama-server first, then re-run this script."
    exit 1
fi

MODEL=$(curl -sf "${BASE_URL}/v1/models" | python3 -c "import sys,json; print(json.load(sys.stdin)['data'][0]['id'])" 2>/dev/null || echo "unknown")
echo "Model: ${MODEL}"
echo "Running tool-eval-bench (seed=${SEED})..."
echo ""

TOOL_EVAL_BASE_URL="${BASE_URL}" \
TOOL_EVAL_API_KEY="" \
tool-eval-bench --seed "${SEED}" --backend llamacpp --timeout 120 "${EXTRA_ARGS[@]}"
