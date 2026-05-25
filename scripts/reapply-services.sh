#!/usr/bin/env bash
# Reapply systemd service configs from repo to /etc/systemd/system/
# Replaces __USERNAME__ placeholder with current user
# Run as: sudo ./reapply-services.sh [service-alias]
#
# Aliases (for restart):
#   regular, turbo, mtp, mtp-131k, nvfp4-mtp-llama, nvfp4-mtp-llama-131k,
#   nvfp4-mtp-llama-262k, 35b-mtp, 35b-mtp-131k, 35b-mxfp4-mtp,
#   35b-mxfp4-mtp-131k, 35b-nvfp4, 35b-nvfp4-131k, gemma4, gemma4-turbo,
#   gemma4-26b, gemma4-mtp, gemma4-mtp-131k, qwen35b, qwen35b-turbo,
#   qwen3-14b, e4b-flux, qwen25-flux, unsloth-studio,
#   nvfp4, nvfp4-turbo, nvfp4-mtp, nvfp4-mtp-turbo, fp8, fp8-turbo,
#   awq, awq-turbo

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LLAMA_CONFIGS="$REPO_DIR/llama/services"
VLLM_CONFIGS="$REPO_DIR/vllm/services"
USERNAME="${SUDO_USER:-$(whoami)}"

# Alias → systemd service name mapping
declare -A ALIASES=(
    [regular]="llama-server"
    [turbo]="llama-server-turbo"
    [mtp]="llama-server-mtp"
    [mtp-131k]="llama-server-mtp-131k"
    [nvfp4-mtp-llama]="llama-server-nvfp4-mtp"
    [nvfp4-mtp-llama-131k]="llama-server-nvfp4-mtp-131k"
    [nvfp4-mtp-llama-262k]="llama-server-nvfp4-mtp-262k"
    [35b-mtp]="llama-server-35b-mtp"
    [35b-mtp-131k]="llama-server-35b-mtp-131k"
    [35b-mxfp4-mtp]="llama-server-35b-mxfp4-mtp"
    [35b-mxfp4-mtp-131k]="llama-server-35b-mxfp4-mtp-131k"
    [35b-nvfp4]="llama-server-35b-nvfp4"
    [35b-nvfp4-131k]="llama-server-35b-nvfp4-131k"
    [gemma4]="llama-server-gemma4"
    [gemma4-turbo]="llama-server-gemma4-turbo"
    [gemma4-26b]="llama-server-26b-a4b"
    [gemma4-mtp]="llama-server-gemma4-mtp"
    [gemma4-mtp-131k]="llama-server-gemma4-mtp-131k"
    [qwen35b]="llama-server-qwen35b"
    [qwen35b-turbo]="llama-server-qwen35b-turbo"
    [qwen3-14b]="llama-server-qwen3-14b"
    [unsloth-studio]="unsloth-studio"
    [nvfp4]="vllm-qwen3.6-27b-nvfp4"
    [nvfp4-turbo]="vllm-qwen3.6-27b-nvfp4-turbo"
    [nvfp4-mtp]="vllm-qwen3.6-27b-nvfp4-mtp"
    [nvfp4-mtp-turbo]="vllm-qwen3.6-27b-nvfp4-mtp-turbo"
    [fp8]="vllm-qwen3.6-27b-fp8"
    [fp8-turbo]="vllm-qwen3.6-27b-fp8-turbo"
    [awq]="vllm-qwen3.6-27b-awq"
    [awq-turbo]="vllm-qwen3.6-27b-awq-turbo"
)

echo "Reapplying service configs for user: $USERNAME"

# Discover all .service files in repo and apply them
applied=0
skipped=0
for src in "$LLAMA_CONFIGS"/*.service "$VLLM_CONFIGS"/*.service; do
    [[ -f "$src" ]] || continue
    svc="$(basename "$src" .service)"

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
    ((applied++)) || true
done

sudo systemctl daemon-reload
systemctl --user daemon-reload 2>/dev/null || true

# Copy chat_template.jinja to all llama.cpp install dirs
sudo cp "$REPO_DIR/llama/chat_template.jinja" /opt/llama.cpp/chat_template.jinja 2>/dev/null || true
sudo cp "$REPO_DIR/llama/chat_template.jinja" /opt/llama-mtp/chat_template.jinja 2>/dev/null || true

echo "Daemon reloaded. Applied $applied service files."

# Optionally restart a service via alias
MODE="${1:-}"
if [[ -z "$MODE" ]]; then
    echo "No service restarted. Pass an alias to restart one."
    exit 0
fi

# Dual-mode shortcuts (two services)
case "$MODE" in
    e4b-flux)
        echo "Restarting e4b-flux dual mode (E4B + FLUX)..."
        sudo systemctl stop llama-server-e4b flux-schnell 2>/dev/null || true
        sudo systemctl reset-failed llama-server-e4b flux-schnell 2>/dev/null || true
        sudo systemctl restart llama-server-e4b flux-schnell
        echo "  E4B on port 10500, FLUX.1-schnell on port 10501"
        exit 0
        ;;
    qwen25-flux|vl-flux)
        echo "Restarting qwen25-flux dual mode (Qwen2.5-VL + FLUX)..."
        sudo systemctl stop llama-server-qwen2.5-vl-7b flux-schnell 2>/dev/null || true
        sudo systemctl reset-failed llama-server-qwen2.5-vl-7b flux-schnell 2>/dev/null || true
        sudo systemctl restart llama-server-qwen2.5-vl-7b flux-schnell
        echo "  Qwen2.5-VL-7B on port 10500, FLUX.1-schnell on port 10501"
        exit 0
        ;;
esac

# Single-service restart via alias lookup
if [[ -v "ALIASES[$MODE]" ]]; then
    svc="${ALIASES[$MODE]}"
    if [[ "$svc" == "unsloth-studio" ]]; then
        echo "Restarting Unsloth Studio (user service)..."
        systemctl --user restart unsloth-studio
        echo "Done. http://localhost:8888"
    else
        echo "Restarting $svc..."
        sudo systemctl restart "$svc"
        echo "Done."
    fi
else
    echo "Unknown alias: $MODE"
    echo "Available: ${!ALIASES[*]}"
    exit 1
fi
