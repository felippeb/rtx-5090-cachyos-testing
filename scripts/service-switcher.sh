#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POWER_LIMIT=475
DEFAULT_POWER_LIMIT=575
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LLAMA_CONFIGS="$REPO_DIR/llama/services"
VLLM_CONFIGS="$REPO_DIR/vllm/services"
MODE="${1:-turbo}"
SYSTEM_SERVICE_DIR="/etc/systemd/system"
USERNAME="${SUDO_USER:-$(whoami)}"

ALL_SERVICES=(
    "llama-server"
    "llama-server-turbo"
    "llama-server-27b-64k"
    "llama-server-gemma4-turbo"
    "llama-server-gemma4"
    "llama-server-gemma4-mtp-131k"
    "unsloth-studio"
    "llama-server-qwen35b-turbo"
    "llama-server-qwen35b"
    "llama-server-qwen3-14b"
    "llama-server-qwen2.5-vl-7b"
    "llama-server-mtp-131k"
    "llama-server-35b-mtp-131k"
    "llama-server-nvfp4-mtp-131k"
    "llama-server-nvfp4-mtp-262k"
    "llama-server-e4b"
    "llama-server-26b-a4b"
    "llama-server-35b-mxfp4-mtp-131k"
    "llama-server-35b-nvfp4-131k"
    "vllm-qwen3.6-27b-nvfp4"
    "vllm-qwen3.6-27b-nvfp4-turbo"
    "vllm-qwen3.6-27b-nvfp4-mtp"
    "vllm-qwen3.6-27b-nvfp4-mtp-turbo"
    "vllm-qwen3.6-27b-fp8"
    "vllm-qwen3.6-27b-fp8-turbo"
    "vllm-qwen3.6-27b-awq"
    "vllm-qwen3.6-27b-awq-turbo"
    "vllm-qwen3.6-35b-a3b-awq-131k"
    "vllm-qwen2.5-vl-7b"
    "flux-schnell"
    "llama-swap"
    "llama-swap-test"
    "llama-server-router"
)

find_service_file() {
    local file="$1"
    for dir in "$LLAMA_CONFIGS" "$VLLM_CONFIGS"; do
        if [[ -f "$dir/$file" ]]; then
            echo "$dir/$file"
            return 0
        fi
    done
    return 1
}

case "$MODE" in
    stop)
        echo "Killing all inference servers..."
        for svc in "${ALL_SERVICES[@]}"; do
            # User services use systemctl --user
            if [[ "$svc" == "unsloth-studio" ]]; then
                if systemctl --user is-active --quiet "$svc" 2>/dev/null; then
                    echo "Stopping $svc (user service)..."
                    systemctl --user stop "$svc"
                fi
                systemctl --user disable "$svc" 2>/dev/null || true
                continue
            fi
            if systemctl is-active --quiet "$svc" 2>/dev/null; then
                echo "Stopping $svc..."
                sudo systemctl stop "$svc"
            fi
            sudo systemctl disable "$svc" 2>/dev/null || true
        done
        echo "Restoring default power limit (${DEFAULT_POWER_LIMIT}W)..."
        sudo nvidia-smi -pl "$DEFAULT_POWER_LIMIT" 2>/dev/null || echo "  (could not restore power limit — run manually: sudo nvidia-smi -pl $DEFAULT_POWER_LIMIT)"
        echo "Done. GPU is yours."
        exit 0
        ;;
    turbo)
        SERVICE_FILE="llama-server-turbo.service"
        SERVICE_NAME="llama-server-turbo"
        ;;
    qwen)
        SERVICE_FILE="llama-server.service"
        SERVICE_NAME="llama-server"
        ;;
    qwen-turbo)
        SERVICE_FILE="llama-server-turbo.service"
        SERVICE_NAME="llama-server-turbo"
        ;;
    27b-64k)
        SERVICE_FILE="llama-server-27b-64k.service"
        SERVICE_NAME="llama-server-27b-64k"
        ;;
    gemma4-turbo)
        SERVICE_FILE="llama-server-gemma4-turbo.service"
        SERVICE_NAME="llama-server-gemma4-turbo"
        ;;
    gemma4)
        SERVICE_FILE="llama-server-gemma4.service"
        SERVICE_NAME="llama-server-gemma4"
        ;;
    gemma4-mtp-131k)
        SERVICE_FILE="llama-server-gemma4-mtp-131k.service"
        SERVICE_NAME="llama-server-gemma4-mtp-131k"
        ;;
    qwen35b-turbo)
        SERVICE_FILE="llama-server-qwen35b-turbo.service"
        SERVICE_NAME="llama-server-qwen35b-turbo"
        ;;
    qwen35b)
        SERVICE_FILE="llama-server-qwen35b.service"
        SERVICE_NAME="llama-server-qwen35b"
        ;;
    qwen3-14b)
        SERVICE_FILE="llama-server-qwen3-14b.service"
        SERVICE_NAME="llama-server-qwen3-14b"
        ;;
    vl-7b)
        SERVICE_FILE="llama-server-qwen2.5-vl-7b.service"
        SERVICE_NAME="llama-server-qwen2.5-vl-7b"
        ;;
    unsloth-studio)
        # User service - stop all system services first, then start unsloth-studio
        echo "Starting Unsloth Studio (user service)..."
        for svc in "${ALL_SERVICES[@]}"; do
            [[ "$svc" == "unsloth-studio" ]] && continue
            sudo systemctl stop "$svc" 2>/dev/null || true
            sudo systemctl disable "$svc" 2>/dev/null || true
        done
        # Kill stray processes
        for pattern in llama-server vllm; do
            STRAY_PIDS=$(pgrep -af "$pattern" 2>/dev/null | grep -v -E "journalctl|tail|less|grep|grep -v" | awk '{print $1}' || true)
            if [[ -n "$STRAY_PIDS" ]]; then
                echo "  Killing $pattern processes: $STRAY_PIDS"
                kill -9 $STRAY_PIDS 2>/dev/null || true
            fi
        done
        for port in 10500 10501 10503 10504 10505; do
            PID=$(lsof -ti :$port -sTCP:LISTEN 2>/dev/null || true)
            if [[ -n "$PID" ]]; then
                echo "  Killing server on port $port: $PID"
                kill -9 $PID 2>/dev/null || true
            fi
        done
        sleep 2
        # Install/update user service
        SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        USER_SVC_DIR="$HOME/.config/systemd/user"
        mkdir -p "$USER_SVC_DIR"
        USERNAME=$(logname 2>/dev/null || whoami)
        sed "s/__USERNAME__/$USERNAME/g" "$LLAMA_CONFIGS/unsloth-studio.service" > "$USER_SVC_DIR/unsloth-studio.service"
        systemctl --user daemon-reload
        systemctl --user enable --now unsloth-studio
        sleep 3
        if systemctl --user is-active --quiet unsloth-studio; then
            echo "✓ Unsloth Studio running on http://localhost:8888"
            echo "  Open in browser to select/download models"
            echo "Kill all: ./service-switcher.sh stop"
        else
            echo "✗ Failed to start. Check: journalctl --user -u unsloth-studio -n 30"
            exit 1
        fi
        exit 0
        ;;
    e4b)
        SERVICE_FILE="llama-server-e4b.service"
        SERVICE_NAME="llama-server-e4b"
        ;;
    a4b)
        SERVICE_FILE="llama-server-26b-a4b.service"
        SERVICE_NAME="llama-server-26b-a4b"
        ;;
    mtp-131k)
        SERVICE_FILE="llama-server-mtp-131k.service"
        SERVICE_NAME="llama-server-mtp-131k"
        ;;
    35b-mtp-131k)
        SERVICE_FILE="llama-server-35b-mtp-131k.service"
        SERVICE_NAME="llama-server-35b-mtp-131k"
        ;;
    35b-mxfp4-mtp-131k)
        SERVICE_FILE="llama-server-35b-mxfp4-mtp-131k.service"
        SERVICE_NAME="llama-server-35b-mxfp4-mtp-131k"
        ;;
    35b-nvfp4-131k)
        SERVICE_FILE="llama-server-35b-nvfp4-131k.service"
        SERVICE_NAME="llama-server-35b-nvfp4-131k"
        ;;
    nvfp4-mtp-llama-131k)
        SERVICE_FILE="llama-server-nvfp4-mtp-131k.service"
        SERVICE_NAME="llama-server-nvfp4-mtp-131k"
        ;;
    nvfp4-mtp-llama-262k)
        SERVICE_FILE="llama-server-nvfp4-mtp-262k.service"
        SERVICE_NAME="llama-server-nvfp4-mtp-262k"
        ;;
    nvfp4-turbo)
        SERVICE_FILE="vllm-qwen3.6-27b-nvfp4-turbo.service"
        SERVICE_NAME="vllm-qwen3.6-27b-nvfp4-turbo"
        ;;
    nvfp4)
        SERVICE_FILE="vllm-qwen3.6-27b-nvfp4.service"
        SERVICE_NAME="vllm-qwen3.6-27b-nvfp4"
        ;;
    nvfp4-mtp)
        SERVICE_FILE="vllm-qwen3.6-27b-nvfp4-mtp.service"
        SERVICE_NAME="vllm-qwen3.6-27b-nvfp4-mtp"
        ;;
    nvfp4-mtp-turbo)
        SERVICE_FILE="vllm-qwen3.6-27b-nvfp4-mtp-turbo.service"
        SERVICE_NAME="vllm-qwen3.6-27b-nvfp4-mtp-turbo"
        ;;
    fp8-turbo)
        SERVICE_FILE="vllm-qwen3.6-27b-fp8-turbo.service"
        SERVICE_NAME="vllm-qwen3.6-27b-fp8-turbo"
        ;;
    fp8)
        SERVICE_FILE="vllm-qwen3.6-27b-fp8.service"
        SERVICE_NAME="vllm-qwen3.6-27b-fp8"
        ;;
    qwen25-flux|vl-flux)
        SERVICE_FILES=("llama-server-qwen2.5-vl-7b.service" "flux-schnell.service")
        SERVICE_NAMES=("llama-server-qwen2.5-vl-7b" "flux-schnell")
        SERVICE_LABELS=("Qwen2.5-VL" "Flux server")
        SERVICE_URLS=("http://localhost:10500/v1/models" "http://localhost:10501")
        DUAL_MODE=true
        ;;
    e4b-flux)
        SERVICE_FILES=("llama-server-e4b.service" "flux-schnell.service")
        SERVICE_NAMES=("llama-server-e4b" "flux-schnell")
        SERVICE_LABELS=("Gemma 4 E4B" "Flux server")
        SERVICE_URLS=("http://localhost:10500/v1/models" "http://localhost:10501")
        DUAL_MODE=true
        ;;
    awq-35b-131k)
        SERVICE_FILE="vllm-qwen3.6-35b-a3b-awq-131k.service"
        SERVICE_NAME="vllm-qwen3.6-35b-a3b-awq-131k"
        ;;
    awq-turbo)
        SERVICE_FILE="vllm-qwen3.6-27b-awq-turbo.service"
        SERVICE_NAME="vllm-qwen3.6-27b-awq-turbo"
        ;;
    awq)
        SERVICE_FILE="vllm-qwen3.6-27b-awq.service"
        SERVICE_NAME="vllm-qwen3.6-27b-awq"
        ;;
    swap)
        echo "Starting llama-swap proxy (manages qwen + flux-schnell)..."
        for svc in "${ALL_SERVICES[@]}"; do
            if [[ "$svc" == "llama-swap" || "$svc" == "llama-swap-test" ]]; then continue; fi
            sudo systemctl stop "$svc" 2>/dev/null || true
            sudo systemctl disable "$svc" 2>/dev/null || true
        done
        for pattern in llama-server vllm; do
            STRAY_PIDS=$(pgrep -af "$pattern" 2>/dev/null | grep -v -E "journalctl|tail|less|grep|grep -v|llama-swap" | awk '{print $1}' || true)
            if [[ -n "$STRAY_PIDS" ]]; then
                echo "  Killing $pattern processes: $STRAY_PIDS"
                kill -9 $STRAY_PIDS 2>/dev/null || true
            fi
        done
        sleep 2
        sudo systemctl enable --now llama-swap
        sleep 3
        if systemctl is-active --quiet llama-swap; then
            echo "✓ llama-swap running on http://localhost:9292"
            echo "  Qwen: http://localhost:9292/v1/chat/completions (model: qwen)"
            echo "  FLUX: http://localhost:10501/generate (direct)"
            echo "  UI:   http://localhost:9292/ui"
            echo "Kill all: ./service-switcher.sh stop"
        else
            echo "✗ llama-swap failed. Check: journalctl -u llama-swap -n 30"
            exit 1
        fi
        exit 0
        ;;
    router)
        SERVICE_FILE="llama-server-router.service"
        SERVICE_NAME="llama-server-router"
        ;;
    *)
        echo "Usage: $0 [turbo|qwen|qwen-turbo|qwen35b-turbo|qwen35b|qwen3-14b|vl-7b|e4b|a4b|mtp-131k|35b-mtp-131k|35b-mxfp4-mtp-131k|35b-nvfp4-131k|nvfp4-mtp-llama-131k|nvfp4-mtp-llama-262k|gemma4-turbo|gemma4|gemma4-mtp-131k|unsloth-studio|nvfp4-turbo|nvfp4|nvfp4-mtp|nvfp4-mtp-turbo|fp8-turbo|fp8|awq-turbo|awq|awq-35b-131k|qwen25-flux|vl-flux|e4b-flux|swap|router|stop]"
        echo ""
        echo "  llama.cpp:"
        echo "    turbo          - Qwen3.6-27B (131K context, q4_1 KV) [default]"
        echo "    qwen           - Qwen3.6-27B (131K context, q8_0 KV)"
        echo "    qwen-turbo     - Same as turbo"
        echo "    qwen35b        - Qwen3.6-35B-A3B MoE (131K context, f16 KV)"
        echo "    gemma4         - Gemma 4 31B (131K context, f16 KV)"
        echo "    gemma4-mtp-131k - Gemma 4 31B MTP (131K, spec decode + TurboQuant)"
        echo "    mtp-131k       - Qwen3.6-27B MTP (131K, spec decode)"
        echo "    35b-mtp-131k     - Qwen3.6-35B-A3B MTP MoE (131K, spec decode, Q4_K_XL)"
        echo "    35b-mxfp4-mtp-131k - Qwen3.6-35B-A3B MXFP4-MTP MoE (131K, spec decode n=6, Blackwell FP4)"
        echo "    35b-nvfp4-131k   - Qwen3.6-35B-A3B NVFP4 MoE (131K, Blackwell FP4, no MTP)"
        echo "    nvfp4-mtp-llama-131k - Qwen3.6-27B NVFP4-MTP GGUF (131K, spec decode) ⭐ daily driver"
        echo "    nvfp4-mtp-llama-262k - Qwen3.6-27B NVFP4-MTP GGUF (262K, q4_1 KV, spec decode)"
        echo "    e4b            - Gemma 4 E4B vision-language (128K context, image+text+thinking)"
        echo "    unsloth-studio - Unsloth Studio web UI (model selector, port 8888)"
        echo "    a4b            - Gemma 4 26B A4B MoE (128K context, Q4_K_L imatrix)"
        echo ""
        echo "  vLLM:"
        echo "    fp8            - Qwen3.6-27B FP8 official (131K context)"
        echo "    awq            - Qwen3.6-27B AWQ INT4 (131K context)"
        echo "    awq-35b-131k   - Qwen3.6-35B A3B AWQ (132K, reduced VRAM for CrewAI)"
        echo "    nvfp4          - Qwen3.6-27B NVFP4 E2M1 (131K context, compressed-tensors)"
        echo "    nvfp4-turbo    - Qwen3.6-27B NVFP4 E2M1 (230K context, compressed-tensors)"
        echo "    nvfp4-mtp      - Qwen3.6-27B NVFP4-MTP vLLM (131K, modelopt + MTP n=3 spec decode)"
        echo "    nvfp4-mtp-turbo- Qwen3.6-27B NVFP4-MTP vLLM (256K, modelopt + MTP n=3 spec decode)"
        echo ""
        echo "  Dual-model:"
        echo "    qwen25-flux      - Qwen2.5-VL-7B llama.cpp (port 10500) + FLUX.1-schnell (port 10501)"
        echo "    vl-flux          - Alias for qwen25-flux"
        echo ""
        echo "  Proxy:"
        echo "    swap             - llama-swap proxy: Qwen3.6-27B + FLUX.1-schnell (port 9292)"
        echo ""
        echo "  Router (native model switching):"
        echo "    router           - llama.cpp router mode: switch models on demand (port 10505)"
        echo ""
        echo "  stop           - Stop all inference servers"
        exit 1
        ;;
esac

DUAL_MODE=${DUAL_MODE:-false}
if [[ "$DUAL_MODE" == "true" ]]; then
    echo "Starting $MODE mode (dual: ${SERVICE_NAMES[*]})..."
else
    SERVICE_PATH=$(find_service_file "$SERVICE_FILE") || {
        echo "Error: $SERVICE_FILE not found in $LLAMA_CONFIGS or $VLLM_CONFIGS"
        exit 1
    }
    echo "Starting $MODE mode..."
fi

# Stop ALL services forcefully
for svc in "${ALL_SERVICES[@]}"; do
    sudo systemctl stop "$svc" 2>/dev/null || true
    sudo systemctl disable "$svc" 2>/dev/null || true
done

# Kill any stray inference processes not managed by systemd
echo "Cleaning up stray inference processes..."
for pattern in llama-server vllm; do
    STRAY_PIDS=$(pgrep -af "$pattern" 2>/dev/null | grep -v -E "journalctl|tail|less|grep|grep -v" | awk '{print $1}' || true)
    if [[ -n "$STRAY_PIDS" ]]; then
        echo "  Killing $pattern processes: $STRAY_PIDS"
        kill -9 $STRAY_PIDS 2>/dev/null || true
    fi
done
# Kill stray server processes listening on inference ports (server only, not clients)
for port in 10500 10501 10503 10504 10505; do
    PID=$(lsof -ti :$port -sTCP:LISTEN 2>/dev/null || true)
    if [[ -n "$PID" ]]; then
        echo "  Killing server on port $port: $PID"
        kill -9 $PID 2>/dev/null || true
    fi
done
sleep 2

# Wait for all services to actually stop (30s timeout)
STOP_TIMEOUT=30
STOP_ELAPSED=0
echo "Waiting for all services to stop..."
while [[ $STOP_ELAPSED -lt $STOP_TIMEOUT ]]; do
    ANY_ACTIVE=false
    for svc in "${ALL_SERVICES[@]}"; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            ANY_ACTIVE=true
            break
        fi
    done
    if [[ "$ANY_ACTIVE" == "false" ]]; then
        echo "All services stopped."
        break
    fi
    sleep 1
    STOP_ELAPSED=$((STOP_ELAPSED + 1))
done

# Wait for GPU memory to free (at least 20GB free for large models, 12GB for dual-mode, 60s timeout)
MIN_FREE=20000
if [[ "$DUAL_MODE" == "true" ]]; then
    MIN_FREE=12000
elif [[ "${SERVICE_NAME:-}" == "llama-server-qwen2.5-vl-7b" ]]; then
    MIN_FREE=12000
fi
TIMEOUT=120
ELAPSED=0
FREE_MIB=0
echo "Waiting for GPU memory to free (target: ${MIN_FREE} MiB)..."
while [[ $ELAPSED -lt $TIMEOUT ]]; do
    FREE_MIB=$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
    if [[ -n "$FREE_MIB" ]] && (( FREE_MIB >= MIN_FREE )); then
        echo "GPU free: ${FREE_MIB} MiB - proceeding."
        break
    fi
    if (( ELAPSED % 20 == 0 && ELAPSED > 0 )); then
        echo "  ... ${FREE_MIB} MiB free, waiting... (${ELAPSED}s/${TIMEOUT}s)"
    fi
    sleep 2
    ELAPSED=$((ELAPSED + 2))
done

if (( FREE_MIB < MIN_FREE )); then
    echo "Warning: GPU memory not fully freed after ${TIMEOUT}s (${FREE_MIB} MiB free, needed ${MIN_FREE} MiB). Proceeding anyway."
fi

USERNAME=$(logname 2>/dev/null || whoami)

if [[ "$DUAL_MODE" == "true" ]]; then
    for idx in "${!SERVICE_FILES[@]}"; do
        svc_file="${SERVICE_FILES[$idx]}"
        svc_name="${SERVICE_NAMES[$idx]}"
        svc_path=$(find_service_file "$svc_file") || {
            echo "Error: $svc_file not found in $LLAMA_CONFIGS or $VLLM_CONFIGS"
            exit 1
        }
        sudo systemctl reset-failed "$svc_name" 2>/dev/null || true
        sed "s/__USERNAME__/$USERNAME/g" "$svc_path" | sudo tee "$SYSTEM_SERVICE_DIR/$svc_name.service" > /dev/null
    done
    sudo systemctl daemon-reload

    FIRST_NAME="${SERVICE_NAMES[0]}"
    sudo systemctl enable --now "$FIRST_NAME"
    echo "Waiting for $FIRST_NAME to start..."
    FIRST_WAIT=0
    FIRST_TIMEOUT=60
    while [[ $FIRST_WAIT -lt $FIRST_TIMEOUT ]]; do
        if systemctl is-active --quiet "$FIRST_NAME"; then
            break
        fi
        sleep 2
        FIRST_WAIT=$((FIRST_WAIT + 2))
    done
    if systemctl is-active --quiet "$FIRST_NAME"; then
        echo "✓ $FIRST_NAME started."
    else
        echo "✗ Failed to start $FIRST_NAME. Check logs:"
        echo "sudo journalctl -u $FIRST_NAME --no-pager -n 50"
        exit 1
    fi

    for idx in "${!SERVICE_NAMES[@]}"; do
        if [[ $idx -eq 0 ]]; then continue; fi
        svc_name="${SERVICE_NAMES[$idx]}"
        sudo systemctl enable --now "$svc_name"
        echo "Waiting for $svc_name to start..."
        WAIT=0
        TIMEOUT=90
        while [[ $WAIT -lt $TIMEOUT ]]; do
            if systemctl is-active --quiet "$svc_name"; then
                break
            fi
            sleep 2
            WAIT=$((WAIT + 2))
        done
        if systemctl is-active --quiet "$svc_name"; then
            echo "✓ $svc_name started."
        else
            echo "✗ Failed to start $svc_name. Check logs:"
            echo "sudo journalctl -u $svc_name --no-pager -n 50"
            exit 1
        fi
    done

    echo ""
    echo "Setting power limit to ${POWER_LIMIT}W..."
    sudo nvidia-smi -pl "$POWER_LIMIT" 2>/dev/null || echo "  (could not set power limit — run manually: sudo nvidia-smi -pl $POWER_LIMIT)"
    echo "✓ All dual-model services running."
    for idx in "${!SERVICE_NAMES[@]}"; do
        label="${SERVICE_LABELS[$idx]:-${SERVICE_NAMES[$idx]}}"
        url="${SERVICE_URLS[$idx]:-}"
        if [[ -n "$url" ]]; then
            printf "  %-13s %s\n" "$label:" "$url"
        else
            printf "  %-13s %s\n" "$label:" "${SERVICE_NAMES[$idx]}"
        fi
    done
    echo "  Kill all: ./service-switcher.sh stop"
else
    SERVICE_PATH=$(find_service_file "$SERVICE_FILE") || {
        echo "Error: $SERVICE_FILE not found in $LLAMA_CONFIGS or $VLLM_CONFIGS"
        exit 1
    }

    sudo systemctl reset-failed "$SERVICE_NAME" 2>/dev/null || true

    sed "s/__USERNAME__/$USERNAME/g" "$SERVICE_PATH" | sudo tee "$SYSTEM_SERVICE_DIR/$SERVICE_NAME.service" > /dev/null

    sudo systemctl daemon-reload

    sudo systemctl enable --now "$SERVICE_NAME"

    sleep 3
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        echo "Setting power limit to ${POWER_LIMIT}W..."
        sudo nvidia-smi -pl "$POWER_LIMIT" 2>/dev/null || echo "  (could not set power limit — run manually: sudo nvidia-smi -pl $POWER_LIMIT)"
        echo "✓ $SERVICE_NAME started successfully."
        echo "Kill all: ./service-switcher.sh stop"
    else
        echo "✗ Failed to start. Check logs:"
        echo "sudo journalctl -u $SERVICE_NAME --no-pager -n 50"
        exit 1
    fi
fi
