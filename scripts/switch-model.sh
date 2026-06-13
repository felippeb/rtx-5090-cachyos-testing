#!/usr/bin/env bash
# Local model switcher — reads config/models.yaml, manages llama-server via systemd user units.
# Usage: ./switch-model.sh <model-key|status|list|stop|logs>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_DIR="$SCRIPT_DIR/config"
MODELS_YAML="$CONFIG_DIR/models.yaml"

LLAMA_BIN="${LLAMA_BIN:-$HOME/.local/bin/llama-server}"
MODELS_DIR="${RTX_MODELS:-$HOME/.local/share/rtx-testing/models}"
RTX_CONFIG="${RTX_CONFIG:-$HOME/.config/rtx-testing}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail()  { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }

yaml_get() {
    local file="$1" key="$2" section="$3"
    awk -v section="  $section:" -v key="    $key:" '
        $0 ~ section { in_section=1; next }
        in_section && $0 ~ key {
            sub(/^[[:space:]]*[^:]+:[[:space:]]*/, "")
            gsub(/"/, "")
            gsub(/[[:space:]]+$/, "")
            print
            exit
        }
        in_section && /^  [a-z]/ { in_section=0 }
    ' "$file"
}

yaml_get_block() {
    local file="$1" key="$2" section="$3"
    awk -v section="  $section:" -v key="    $key:" '
    $0 ~ section { in_section=1; next }
    in_section {
        if ($0 ~ key) {
            sub(/^[[:space:]]*[^:]+:[[:space:]]*/, "")
            if ($0 ~ /^[|>]/) { block=1; next }
            if (block) {
                if (/^      /) { sub(/^      /, ""); print }
                else { exit }
            } else { print; exit }
        }
        if (block) {
            if (/^      /) { sub(/^      /, ""); print }
            else { exit }
        }
        if (/^  [a-z]/) { exit }
    }
    ' "$file"
}

sanitize_unit_name() {
    echo "$1" | sed 's/[^a-zA-Z0-9-]/-/g'
}

do_list() {
    echo -e "${CYAN}Registered Models${NC}"
    echo "──────────────────────────────────────────────────────"
    printf "  %-42s %s\n" "MODEL KEY" "DISPLAY NAME"
    echo "──────────────────────────────────────────────────────"
    awk '/^  [a-zA-Z].*:/ { gsub(/^  /, ""); gsub(/:$/, ""); print }' "$MODELS_YAML" | while IFS= read -r key; do
        local display
        display=$(yaml_get "$MODELS_YAML" "display_name" "$key" 2>/dev/null)
        [[ -n "$display" ]] && printf "  %-42s %s\n" "$key" "$display"
    done
    echo ""
    info "Use: $0 <model-key> to start a model"
    exit 0
}

do_status() {
    echo -e "${CYAN}Running llama-server instances:${NC}"
    local running=false

    for unit in $(systemctl --user list-units --no-legend 'rtx-*' 2>/dev/null | awk '{print $1}'); do
        echo "  ● $unit ($(systemctl --user is-active "$unit" 2>/dev/null || echo inactive))"
        running=true
    done

    for unit in $(systemctl list-units --no-legend 'llama-server-*' 2>/dev/null | awk '{print $1}'); do
        echo "  ● $unit ($(systemctl is-active "$unit" 2>/dev/null || echo inactive)) [legacy]"
        running=true
    done

    $running || echo "  (none)"
    echo ""
    info "GPU:"
    nvidia-smi --query-gpu=name,memory.used,memory.total,power.draw,temperature.gpu \
        --format=csv,noheader 2>/dev/null || warn "nvidia-smi unavailable"
    exit 0
}

resolve_model_key() {
    local target="$1"

    local alias_match
    alias_match=$(awk -v t="$target" '
        /^  [a-zA-Z].*:/ { gsub(/^  /, ""); gsub(/:$/, ""); current=$0 }
        current != "" && /    aliases:/ {
            gsub(/.*aliases:[[:space:]]*\[/, "")
            gsub(/\].*/, "")
            n = split($0, arr, ",")
            for (i=1; i<=n; i++) {
                gsub(/[[:space:]]+/, "", arr[i])
                gsub(/"/, "", arr[i])
                if (arr[i] == t) { print current; exit }
            }
        }
    ' "$MODELS_YAML" 2>/dev/null)
    if [[ -n "$alias_match" ]]; then
        echo "$alias_match"
        return
    fi

    local exact
    exact=$(grep "^  ${target}:" "$MODELS_YAML" 2>/dev/null && echo "$target")
    if [[ -n "$exact" ]]; then
        echo "$exact"
        return
    fi

    local matches
    matches=$(grep -E "^  [a-zA-Z].*:" "$MODELS_YAML" | grep -i "$target" | head -5)
    if [[ -z "$matches" ]]; then
        return
    fi
    local count
    count=$(echo "$matches" | wc -l)
    if [[ "$count" -eq 1 ]]; then
        echo "$matches" | sed 's/^  //; s/:$//'
        return
    fi
    echo "$matches" | sed 's/^  //; s/:$//' | awk '{ print length, $0 }' | sort -n | head -1 | cut -d' ' -f2-
}

check_safety_tier() {
    local model_key="$1"
    local tier
    tier=$(yaml_get "$MODELS_YAML" "context_safety_tier" "$model_key")
    if [[ "$tier" == "experimental" ]]; then
        warn "Context size is EXPERIMENTAL — stability not guaranteed."
    fi
}

ensure_model_downloaded() {
    local resolved_key="$1"

    local hf_repo
    hf_repo=$(yaml_get "$MODELS_YAML" "hf_repo" "$resolved_key")
    if [[ -z "$hf_repo" || "$hf_repo" == "null" ]]; then
        return 0
    fi

    local filename model_dir_sub
    filename=$(yaml_get "$MODELS_YAML" "filename" "$resolved_key")
    model_dir_sub=$(yaml_get "$MODELS_YAML" "model_dir" "$resolved_key")
    [[ -z "$model_dir_sub" ]] && model_dir_sub="$resolved_key"

    local model_dir="$MODELS_DIR/$model_dir_sub"
    local model_file="$model_dir/$filename"

    if [[ -n "$filename" && ! -f "$model_file" ]]; then
        info "Downloading $filename from $hf_repo..."
        mkdir -p "$model_dir"
        HF_XET_HIGH_PERFORMANCE=1 huggingface-cli download "$hf_repo" "$filename" \
            --local-dir "$model_dir" ${HF_TOKEN:+--token "$HF_TOKEN"}
        ok "Downloaded $filename"
    elif [[ -n "$filename" ]]; then
        ok "Model exists: $model_file"
    fi

    local mmproj_filename
    mmproj_filename=$(yaml_get "$MODELS_YAML" "mmproj_filename" "$resolved_key")
    if [[ -n "$mmproj_filename" ]]; then
        local mmproj_repo
        mmproj_repo=$(yaml_get "$MODELS_YAML" "mmproj_hf_repo" "$resolved_key")
        [[ -z "$mmproj_repo" ]] && mmproj_repo="$hf_repo"
        local mmproj_file="$model_dir/$mmproj_filename"
        if [[ ! -f "$mmproj_file" ]]; then
            info "Downloading $mmproj_filename from $mmproj_repo..."
            HF_XET_HIGH_PERFORMANCE=1 huggingface-cli download "$mmproj_repo" "$mmproj_filename" \
                --local-dir "$model_dir" ${HF_TOKEN:+--token "$HF_TOKEN"}
            ok "Downloaded $mmproj_filename"
        else
            ok "mmproj exists: $mmproj_filename"
        fi
    fi
}

stop_existing() {
    local port="${1:-10500}"

    # Stop user-space rtx-* units (new-style)
    local active_units
    active_units=$(systemctl --user list-units --no-legend 'rtx-*' 2>/dev/null | awk '{print $1}' || true)
    if [[ -n "$active_units" ]]; then
        info "Stopping user model(s): $active_units"
        for unit in $active_units; do
            systemctl --user stop "$unit" 2>/dev/null || true
        done
    fi

    # Stop old system-level llama-server-* units (legacy)
    local system_units
    system_units=$(systemctl list-units --no-legend 'llama-server-*' 2>/dev/null | awk '{print $1}' || true)
    if [[ -n "$system_units" ]]; then
        info "Stopping legacy system model(s): $system_units"
        for unit in $system_units; do
            sudo systemctl stop "${unit%.service}" 2>/dev/null || true
        done
    fi

    # Kill any stray llama-server processes holding the port
    local pids
    pids=$(lsof -ti :"$port" 2>/dev/null || true)
    if [[ -n "$pids" ]]; then
        info "Killing stray process(es) on port $port: $pids"
        echo "$pids" | xargs kill -9 2>/dev/null || true
    fi

    # Wait for port to free
    local retries=0
    while lsof -i :"$port" >/dev/null 2>&1 && [[ $retries -lt 20 ]]; do
        sleep 0.5
        retries=$((retries + 1))
    done

    # Wait for GPU memory to free (target: 20GB, 60s timeout)
    if command -v nvidia-smi &>/dev/null; then
        local MIN_FREE=20000
        local TIMEOUT=60
        local ELAPSED=0
        local FREE_MIB=0

        info "Waiting for GPU memory to free (target: ${MIN_FREE} MiB)..."
        while [[ $ELAPSED -lt $TIMEOUT ]]; do
            FREE_MIB=$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ') || true
            if [[ -n "$FREE_MIB" ]] && (( FREE_MIB >= MIN_FREE )); then
                ok "GPU free: ${FREE_MIB} MiB — proceeding."
                break
            fi
            if (( ELAPSED % 20 == 0 && ELAPSED > 0 )); then
                info "  ... ${FREE_MIB} MiB free, waiting... (${ELAPSED}s/${TIMEOUT}s)"
            fi
            sleep 1
            ELAPSED=$((ELAPSED + 1))
        done

        if (( FREE_MIB < MIN_FREE )); then
            warn "GPU memory not fully freed after ${TIMEOUT}s (${FREE_MIB} MiB free, needed ${MIN_FREE} MiB)."
            warn "Proceeding anyway — model may fall back to CPU."
        fi
    fi
}

ensure_binary() {
    if [[ ! -x "$LLAMA_BIN" ]]; then
        fail "llama-server not found at $LLAMA_BIN. Build or install it first."
    fi
}

check_power_limit() {
    local current_target=475
    local current
    current=$(nvidia-smi --query-gpu=power.limit --format=csv,noheader 2>/dev/null | head -1 | cut -d. -f1 || echo "")
    if [[ -n "$current" && "$current" -ne "$current_target" ]]; then
        warn "GPU power limit is ${current}W — expected ${current_target}W for stable inference."
        warn "Set with: sudo nvidia-smi -pl ${current_target}"
    fi
}

set_power_limit() {
    local target="${1:-475}"
    if nvidia-smi -pl "$target" 2>/dev/null; then
        ok "GPU power limit set to ${target}W"
    else
        fail "Cannot set power limit (need sudo). Run: sudo nvidia-smi -pl $target"
    fi
}

ensure_config() {
    if [[ ! -f "$RTX_CONFIG/chat_template.jinja" ]]; then
        mkdir -p "$RTX_CONFIG"
        if [[ -f "$CONFIG_DIR/chat_template.jinja" ]]; then
            cp "$CONFIG_DIR/chat_template.jinja" "$RTX_CONFIG/chat_template.jinja"
        elif [[ -f "$MODELS_DIR/chat_template.jinja" ]]; then
            cp "$MODELS_DIR/chat_template.jinja" "$RTX_CONFIG/chat_template.jinja"
        fi
    fi
}

do_switch() {
    local target="$1"

    local resolved_key
    resolved_key=$(resolve_model_key "$target")
    if [[ -z "$resolved_key" ]]; then
        fail "Model '$target' not found in registry. Run: $0 list"
    fi

    ensure_binary
    ensure_config
    ensure_model_downloaded "$resolved_key"
    check_safety_tier "$resolved_key"
    check_power_limit

    local server_args
    server_args=$(yaml_get_block "$MODELS_YAML" "server_args" "$resolved_key" | tr '\n' ' ')
    if [[ -z "$server_args" ]]; then
        fail "No server_args defined for '$resolved_key'"
    fi

    local display
    display=$(yaml_get "$MODELS_YAML" "display_name" "$resolved_key")
    server_args="${server_args//\{models_dir\}/$MODELS_DIR}"
    server_args="${server_args//\{config_dir\}/$RTX_CONFIG}"

    info "Switching to: $display"
    info "Args: $LLAMA_BIN $server_args"
    stop_existing

    local unit_name
    unit_name="rtx-$(sanitize_unit_name "$resolved_key")"

    info "Starting $unit_name via systemd..."
    eval "args=($server_args)"
    local LIB_PATH="$(dirname "$LLAMA_BIN")"
    systemd-run --user --unit="$unit_name" \
        --property=Restart=on-failure \
        --property=RestartSec=5 \
        --property=Type=simple \
        --working-directory="$HOME" \
        --setenv=CUDA_VISIBLE_DEVICES=0 \
        --setenv=GGML_CUDA_ENABLE_PEER_COPY=1 \
        --setenv=LD_LIBRARY_PATH="$LIB_PATH" \
        --collect \
        "$LLAMA_BIN" "${args[@]}"

    ok "Started $display (unit: $unit_name)"
    echo ""
    info "Logs:   journalctl --user -u $unit_name -f"
    info "Stop:   systemctl --user stop $unit_name"
    info "Status: $0 status"
}

do_logs() {
    local target="$1"
    if [[ -z "$target" ]]; then
        local active
        active=$(systemctl --user list-units --no-legend 'rtx-*' 2>/dev/null | head -1 | awk '{print $1}' || true)
        if [[ -z "$active" ]]; then
            fail "No running model. Specify a model key or start one first."
        fi
        journalctl --user -u "$active" -f
    else
        local resolved_key
        resolved_key=$(resolve_model_key "$target" 2>/dev/null || echo "")
        if [[ -z "$resolved_key" ]]; then
            journalctl --user -u "rtx-$(sanitize_unit_name "$target")" -f 2>/dev/null || \
                fail "No unit found for '$target'"
        else
            journalctl --user -u "rtx-$(sanitize_unit_name "$resolved_key")" -f
        fi
    fi
}

do_stop() {
    local target="$1"
    if [[ -n "$target" ]]; then
        local resolved_key
        resolved_key=$(resolve_model_key "$target" 2>/dev/null || echo "")
        local unit_name
        if [[ -n "$resolved_key" ]]; then
            unit_name="rtx-$(sanitize_unit_name "$resolved_key")"
        else
            unit_name="rtx-$(sanitize_unit_name "$target")"
        fi
        systemctl --user stop "$unit_name" 2>/dev/null && ok "Stopped $unit_name" || warn "Not running"
    else
    local active_units
    active_units=$(systemctl --user list-units --no-legend 'rtx-*' 2>/dev/null | awk '{print $1}' || true)
    if [[ -z "$active_units" ]]; then
        info "No running models."
    else
        for unit in $active_units; do
            systemctl --user stop "$unit" 2>/dev/null || true
        done
        ok "Stopped all models"
    fi
    fi
}

print_usage() {
    echo "Usage: $0 <model-key|status|list|stop|logs>"
    echo ""
    echo "Commands:"
    echo "  list              List all registered models"
    echo "  status            Show running model(s) + GPU info"
    echo "  <model-key>       Start a model (stops others first)"
    echo "  stop [model]      Stop model(s). Omitting model stops all."
    echo "  logs [model]      Follow logs. Omitting model picks running one."
    echo "  set-power-limit [W]  Set GPU power limit (default 475W)"
    echo ""
    echo "Examples:"
    echo "  $0 nvfp4-mtp     Start daily driver (Qwen3.6-27B NVFP4-MTP)"
    echo "  $0 nvfp4-long    Start 262K context variant"
    echo "  $0 status        Check what's running"
    echo "  $0 logs          Follow logs of running model"
    echo "  $0 set-power-limit         Set GPU to 475W (may need sudo)"
    echo "  $0 stop          Stop all models"
}

if [ $# -eq 0 ]; then
    print_usage
    exit 1
fi

case "$1" in
    status)  do_status ;;
    list)    do_list ;;
    stop)    do_stop "${2:-}" ;;
    logs)    do_logs "${2:-}" ;;
    set-power-limit) set_power_limit "${2:-475}" ;;
    *)       do_switch "$1" ;;
esac
