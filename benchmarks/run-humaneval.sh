#!/usr/bin/env bash
# Run HumanEval+ benchmark against a local llama-server
# Usage: ./run-humaneval.sh [--port PORT] [--resume] [--max N]
#
# Examples:
#   ./run-humaneval.sh                          # Full 164-problem benchmark
#   ./run-humaneval.sh --short                  # Quick 20-problem subset
#   ./run-humaneval.sh --resume                 # Resume previous partial run
#   ./run-humaneval.sh --port 10503             # Different server port

set -euo pipefail

PORT=10500
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --short)
            EXTRA_ARGS+=("--max-problems" "20")
            shift
            ;;
        --port)
            PORT="$2"
            shift 2
            ;;
        --resume)
            EXTRA_ARGS+=("--resume")
            shift
            ;;
        --max)
            EXTRA_ARGS+=("--max-problems" "$2")
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--short] [--port PORT] [--resume] [--max N]"
            exit 1
            ;;
    esac
done

BASE_URL="http://localhost:${PORT}"

echo "Checking server at ${BASE_URL}..."
if ! curl -sf "${BASE_URL}/health" >/dev/null 2>&1; then
    echo "ERROR: Server not responding at ${BASE_URL}"
    echo "Start a llama-server first, then re-run this script."
    exit 1
fi

MODEL=$(curl -sf "${BASE_URL}/v1/models" | python3 -c "import sys,json; print(json.load(sys.stdin)['data'][0]['id'])" 2>/dev/null || echo "unknown")
echo "Model: ${MODEL}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}"

~/.venv/bin/python3 humaneval.py --port "${PORT}" "${EXTRA_ARGS[@]}"
