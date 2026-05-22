#!/usr/bin/env bash
# Reapply systemd service configs from repo to /etc/systemd/system/
# Replaces __USERNAME__ placeholder with current user
# Run as: sudo ./reapply-services.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LLAMA_CONFIGS="$REPO_DIR/llama/services"
VLLM_CONFIGS="$REPO_DIR/vllm/services"
USERNAME="${SUDO_USER:-$(whoami)}"

ALL_SERVICES=(
    "llama-server"
    "llama-server-turbo"
    "llama-server-26b-a4b"
    "llama-server-27b-64k"
    "llama-server-gemma4"
    "llama-server-gemma4-turbo"
    "llama-server-e4b"
    "llama-server-qwen35b"
    "llama-server-qwen35b-turbo"
    "llama-server-qwen2.5-vl-7b"
    "llama-server-mtp"
    "llama-server-mtp-131k"
    "llama-server-35b-mtp"
    "llama-server-35b-mtp-131k"
    "llama-server-nvfp4-mtp"
    "llama-server-nvfp4-mtp-131k"
    "llama-server-nvfp4-mtp-262k"
    "llama-server-35b-mxfp4-mtp"
    "llama-server-35b-mxfp4-mtp-131k"
    "llama-server-35b-nvfp4"
    "llama-server-35b-nvfp4-131k"
    "llama-server-qwen3-14b"
    "llama-server-gemma4-mtp"
    "llama-server-gemma4-mtp-131k"
    "unsloth-studio"
    "vllm-qwen3.6-27b-nvfp4"
    "vllm-qwen3.6-27b-nvfp4-turbo"
    "vllm-qwen3.6-27b-nvfp4-mtp"
    "vllm-qwen3.6-27b-nvfp4-mtp-turbo"
    "vllm-qwen3.6-27b-fp8"
    "vllm-qwen3.6-27b-fp8-turbo"
    "vllm-qwen3.6-27b-awq"
    "vllm-qwen3.6-27b-awq-turbo"
    "vllm-qwen3.6-35b-a3b-awq-131k"
    "flux-schnell"

)

echo "Reapplying service configs for user: $USERNAME"

for svc in "${ALL_SERVICES[@]}"; do
    src=""
    for dir in "$LLAMA_CONFIGS" "$VLLM_CONFIGS"; do
        candidate="$dir/${svc}.service"
        if [[ -f "$candidate" ]]; then
            src="$candidate"
            break
        fi
    done
    if [[ -n "$src" ]]; then
        # User services go to ~/.config/systemd/user/, system services to /etc/systemd/system/
        if [[ "$svc" == "unsloth-studio" ]]; then
            USER_SVC_DIR="$HOME/.config/systemd/user"
            mkdir -p "$USER_SVC_DIR"
            sed "s/__USERNAME__/$USERNAME/g" "$src" > "$USER_SVC_DIR/${svc}.service"
            echo "  Applied: ${svc}.service (user service)"
        else
            sed "s/__USERNAME__/$USERNAME/g" "$src" | sudo tee "/etc/systemd/system/${svc}.service" > /dev/null
            echo "  Applied: ${svc}.service"
        fi
    else
        echo "  Skipped: ${svc}.service (not found)"
    fi
done

# Disable all services so nothing autostarts
for svc in llama-server llama-server-turbo; do
    sudo systemctl disable "$svc" 2>/dev/null || true
done

sudo systemctl daemon-reload
systemctl --user daemon-reload 2>/dev/null || true

# Clean up old unsloth-named service files
for old in \
    "llama-server-unsloth-mtp" \
    "llama-server-unsloth-mtp-131k" \
    "llama-server-unsloth-35b-mtp" \
    "llama-server-unsloth-35b-mtp-131k" \
    "llama-server-unsloth-mtp-unsloth" \
    "llama-server-unsloth-mtp-131k-unsloth" \
    "llama-server-unsloth-35b-mtp-unsloth" \
    "llama-server-unsloth-35b-mtp-131k-unsloth"; do
    sudo rm -f "/etc/systemd/system/${old}.service" 2>/dev/null || true
done

# Copy chat_template.jinja to all llama.cpp install dirs used by services
sudo cp "$REPO_DIR/llama/chat_template.jinja" /opt/llama.cpp/chat_template.jinja 2>/dev/null || true
sudo cp "$REPO_DIR/llama/chat_template.jinja" /opt/llama-mtp/chat_template.jinja 2>/dev/null || true

echo "Daemon reloaded. All services disabled (manual start only)."

# Optionally restart a specific service
MODE="${1:-}"
case "$MODE" in
    regular)
        echo "Restarting llama-server..."
        sudo systemctl restart llama-server
        ;;
    turbo|qwen-turbo)
        SERVICE_TO_RESTART="llama-server-turbo"
        ;;
    qwen35b)
        SERVICE_TO_RESTART="llama-server-qwen35b"
        ;;
    qwen35b-turbo)
        SERVICE_TO_RESTART="llama-server-qwen35b-turbo"
        ;;
    gemma4)
        SERVICE_TO_RESTART="llama-server-gemma4"
        ;;
    gemma4-turbo)
        SERVICE_TO_RESTART="llama-server-gemma4-turbo"
        ;;
    gemma4-26b)
        SERVICE_TO_RESTART="llama-server-26b-a4b"
        ;;
    gemma4-mtp)
        SERVICE_TO_RESTART="llama-server-gemma4-mtp"
        ;;
    gemma4-mtp-131k)
        SERVICE_TO_RESTART="llama-server-gemma4-mtp-131k"
        ;;
    mtp)
        SERVICE_TO_RESTART="llama-server-mtp"
        ;;
    mtp-131k)
        SERVICE_TO_RESTART="llama-server-mtp-131k"
        ;;
    35b-mtp)
        SERVICE_TO_RESTART="llama-server-35b-mtp"
        ;;
    35b-mtp-131k)
        SERVICE_TO_RESTART="llama-server-35b-mtp-131k"
        ;;
    nvfp4-mtp-llama)
        SERVICE_TO_RESTART="llama-server-nvfp4-mtp"
        ;;
    nvfp4-mtp-llama-131k)
        SERVICE_TO_RESTART="llama-server-nvfp4-mtp-131k"
        ;;
    nvfp4-mtp-llama-262k)
        SERVICE_TO_RESTART="llama-server-nvfp4-mtp-262k"
        ;;
    35b-mxfp4-mtp)
        SERVICE_TO_RESTART="llama-server-35b-mxfp4-mtp"
        ;;
    35b-mxfp4-mtp-131k)
        SERVICE_TO_RESTART="llama-server-35b-mxfp4-mtp-131k"
        ;;
    35b-nvfp4)
        SERVICE_TO_RESTART="llama-server-35b-nvfp4"
        ;;
    35b-nvfp4-131k)
        SERVICE_TO_RESTART="llama-server-35b-nvfp4-131k"
        ;;
    qwen3-14b)
        SERVICE_TO_RESTART="llama-server-qwen3-14b"
        ;;
    unsloth-studio)
        echo "Restarting Unsloth Studio (user service)..."
        systemctl --user restart unsloth-studio
        echo "Done. http://localhost:8888"
        exit 0
        ;;
    nvfp4)
        SERVICE_TO_RESTART="vllm-qwen3.6-27b-nvfp4"
        ;;
    nvfp4-turbo)
        SERVICE_TO_RESTART="vllm-qwen3.6-27b-nvfp4-turbo"
        ;;
    nvfp4-mtp)
        SERVICE_TO_RESTART="vllm-qwen3.6-27b-nvfp4-mtp"
        ;;
    nvfp4-mtp-turbo)
        SERVICE_TO_RESTART="vllm-qwen3.6-27b-nvfp4-mtp-turbo"
        ;;
    fp8)
        SERVICE_TO_RESTART="vllm-qwen3.6-27b-fp8"
        ;;
    fp8-turbo)
        SERVICE_TO_RESTART="vllm-qwen3.6-27b-fp8-turbo"
        ;;
    awq)
        SERVICE_TO_RESTART="vllm-qwen3.6-27b-awq"
        ;;
    awq-turbo)
        SERVICE_TO_RESTART="vllm-qwen3.6-27b-awq-turbo"
        ;;
    e4b-flux)
        echo "Restarting e4b-flux dual mode (E4B + FLUX)..."
        for svc in "llama-server-e4b" "flux-schnell"; do
            echo "  Stopping $svc..."
            sudo systemctl stop "$svc" 2>/dev/null || true
        done
        for svc in "llama-server-e4b" "flux-schnell"; do
            echo "  Restarting $svc..."
            sudo systemctl reset-failed "$svc" 2>/dev/null || true
            sudo systemctl restart "$svc"
        done
        echo "  E4B (Gemma 4 E4B) on port 10500"
        echo "  FLUX.1-schnell on port 10501"
        exit 0
        ;;
    qwen25-flux|vl-flux)
        echo "Restarting qwen25-flux dual mode (Qwen2.5-VL + FLUX)..."
        for svc in "llama-server-qwen2.5-vl-7b" "flux-schnell"; do
            echo "  Stopping $svc..."
            sudo systemctl stop "$svc" 2>/dev/null || true
        done
        for svc in "llama-server-qwen2.5-vl-7b" "flux-schnell"; do
            echo "  Restarting $svc..."
            sudo systemctl reset-failed "$svc" 2>/dev/null || true
            sudo systemctl restart "$svc"
        done
        echo "  Qwen2.5-VL-7B on port 10500"
        echo "  FLUX.1-schnell on port 10501"
        exit 0
        ;;
    *)
        echo "No service restarted. Pass 'regular' or 'turbo' to restart one."
        ;;
esac

echo "Done."
