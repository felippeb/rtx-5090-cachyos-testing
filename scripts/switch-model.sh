#!/usr/bin/env bash
# Parameterized model switcher — reads config/models.yaml to resolve services.
# Usage: ./switch-model.sh <model-key> [options]
#        ./switch-model.sh status
#        ./switch-model.sh list
#
# This script does NOT kill running models unless you explicitly switch.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_DIR="$SCRIPT_DIR/config"
COMPOSE_DIR="$SCRIPT_DIR/docker"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"
COMPOSE="docker compose --project-name rtx-inference -f $COMPOSE_FILE"
MODELS_YAML="$CONFIG_DIR/models.yaml"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail()  { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }

# ─── Parse a YAML value (simple, no nested structures) ──────────
yaml_get() {
    local file="$1" key="$2" section="$3"
    # Extract the section block, then find the key
    awk -v section="$section" -v key="$key" '
        $0 ~ "^  " section ":" { in_section=1; next }
        in_section && /^    [a-z]/ {
            if ($0 ~ "^    " key ":") {
                sub(/^    [^:]+: */, "")
                gsub(/"/, "")
                print
                exit
            }
        }
        in_section && /^  [a-z]/ { in_section=0 }
    ' "$file"
}

# ─── List all models from registry ──────────────────────────────
do_list() {
    echo -e "${BOLD}${CYAN}Registered Models${NC}"
    echo -e "${NC}$(printf '%.0s-' {1..70})${NC}"
    printf "  ${BOLD}%-40s${NC} %-10s %s\n" "MODEL KEY" "BACKEND" "SERVICE"
    echo -e "$(printf '%.0s-' {1..70})"

    # Parse models.yaml for display
    local current_section=""
    while IFS= read -r line; do
        if [[ "$line" =~ ^[a-zA-Z] && ! "$line" =~ ^# && "$line" =~ :$ ]]; then
            current_section="${line%%:*}"
        elif [[ "$line" =~ ^[[:space:]]+compose_service: ]]; then
            local service
            service=$(echo "$line" | sed 's/.*compose_service: *//' | tr -d '"')
            local backend
            backend=$(yaml_get "$MODELS_YAML" "backend" "$current_section")
            printf "  %-42s %-10s %s\n" "$current_section" "$backend" "$service"
        fi
    done < "$MODELS_YAML"

    echo ""
    info "Infrastructure services:"
    for svc in router swap webui; do
        local display
        display=$(yaml_get "$MODELS_YAML" "display_name" "$svc")
        printf "  %-42s %s\n" "$svc" "$display"
    done
    echo ""
    info "Use: $0 <model-key> to start a model"
    exit 0
}

# ─── Show status ─────────────────────────────────────────────────
do_status() {
    info "Running containers:"
    $COMPOSE ps 2>/dev/null || warn "No containers running"
    echo ""
    info "GPU status:"
    nvidia-smi --query-gpu=name,memory.used,memory.total,power.draw,temperature.gpu \
        --format=csv,noheader 2>/dev/null || warn "nvidia-smi unavailable"
    exit 0
}

# ─── Resolve model key to compose service ────────────────────────
resolve_service() {
    local model_key="$1"
    yaml_get "$MODELS_YAML" "compose_service" "$model_key"
}

# ─── Check context safety tier ───────────────────────────────────
check_safety_tier() {
    local model_key="$1"
    local tier
    tier=$(yaml_get "$MODELS_YAML" "context_safety_tier" "$model_key")
    if [[ "$tier" == "experimental" ]]; then
        warn "Context size is EXPERIMENTAL — stability not guaranteed."
        warn "Expected issues: higher VRAM usage, possible OOM at long contexts."
    fi
}

# ─── Switch model ────────────────────────────────────────────────
do_switch() {
    local target="$1"
    local stop_first="${2:-true}"

    # Resolve service name
    local service_name
    service_name=$(resolve_service "$target")

    if [[ -z "$service_name" ]]; then
        fail "Model '$target' not found in registry. Run: $0 list"
    fi

    # Safety check
    check_safety_tier "$target"

    local backend
    backend=$(yaml_get "$MODELS_YAML" "backend" "$target")
    local display
    display=$(yaml_get "$MODELS_YAML" "display_name" "$target")
    local context
    context=$(yaml_get "$MODELS_YAML" "context" "$target")

    info "Switching to: $display ($service_name)"
    info "Backend: $backend | Context: ${context:-default}"

    if [[ "$stop_first" == "true" ]]; then
        info "Stopping conflicting inference services..."
        # Only stop other inference containers, not the target
        $COMPOSE stop llama-server-* 2>/dev/null || true
        $COMPOSE stop vllm-* 2>/dev/null || true
        sleep 1
    fi

    info "Starting $service_name..."
    $COMPOSE run --rm "$service_name" &
    local bg_pid=$!

    ok "Started $display (background PID: $bg_pid)"
    echo ""
    info "Logs:   $COMPOSE logs -f $service_name"
    info "Stop:   $COMPOSE stop $service_name"
    info "Status: $0 status"
}

# ─── Print usage ─────────────────────────────────────────────────
print_usage() {
    echo "Usage: $0 <model-key|status|list|stop>"
    echo ""
    echo "Commands:"
    echo "  list              List all registered models"
    echo "  status            Show running containers + GPU info"
    echo "  <model-key>       Start a model (stops others first)"
    echo "  <model-key> no-stop  Start without stopping others"
    echo "  stop <service>    Stop a specific service"
    echo ""
    echo "Examples:"
    echo "  $0 nvfp4-mtp          Start NVFP4-MTP model"
    echo "  $0 gemma4             Start Gemma4"
    echo "  $0 router             Start model router"
    echo "  $0 status             Check what's running"
}

# ─── Main ────────────────────────────────────────────────────────
if [ $# -eq 0 ]; then
    print_usage
    exit 1
fi

case "$1" in
    status)  do_status ;;
    list)    do_list ;;
    stop)
        if [ $# -lt 2 ]; then
            fail "Usage: $0 stop <service-name>"
        fi
        $COMPOSE stop "$2" 2>/dev/null && ok "Stopped $2" || warn "Not running"
        ;;
    *)
        if [ $# -ge 2 ] && [ "$2" = "no-stop" ]; then
            do_switch "$1" "false"
        else
            do_switch "$1" "true"
        fi
        ;;
esac
