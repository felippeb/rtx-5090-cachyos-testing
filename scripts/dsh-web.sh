#!/usr/bin/env bash
# dsh-web — DeepSeek Harness (dsh) Web GUI as a user service.
# Pattern: transient systemd user unit (same as llama-embed / mem0-api).
#   Unit:  dsh-web (--collect: disappears after stop, survives reboots NOT — restart via this script)
#   Serves: http://127.0.0.1:3080 from ~/repos/github/deepseek-harness
# Usage: scripts/dsh-web.sh {start|stop|restart|status|logs [-f] [N]}
set -euo pipefail

REPO_DIR="${DSH_REPO:-$HOME/repos/github/deepseek-harness}"
PNPM_BIN="${PNPM_BIN:-$HOME/.npm-global/bin/pnpm}"
PORT="${DSH_WEB_PORT:-3080}"
UNIT="dsh-web"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail()  { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }

is_running() { systemctl --user is-active --quiet "$UNIT" 2>/dev/null; }

check_port_free() {
    if lsof -i :"$PORT" >/dev/null 2>&1; then
        fail "Port $PORT already in use. Stop the other process first (or set DSH_WEB_PORT)."
    fi
}

ensure_ready() {
    [[ -d "$REPO_DIR" ]] || fail "dsh repo not found at $REPO_DIR (set DSH_REPO to override)"
    [[ -x "$PNPM_BIN" ]] || fail "pnpm not found at $PNPM_BIN (set PNPM_BIN to override)"
    if [[ ! -f "$REPO_DIR/apps/web/dist/index.html" ]]; then
        fail "Frontend dist not built. Run: cd $REPO_DIR && pnpm install && pnpm run build"
    fi
}

wait_http() {
    local url="$1" name="$2" retries=0
    while ! curl -sf "$url" >/dev/null 2>&1; do
        if (( retries >= 60 )); then
            fail "$name did not come up on $url. Logs: journalctl --user -u $UNIT -n 50"
        fi
        sleep 1
        retries=$((retries + 1))
    done
    ok "$name up at $url"
}

start() {
    if is_running; then
        ok "dsh-web already running at http://127.0.0.1:$PORT"
        return
    fi
    ensure_ready
    check_port_free
    info "Starting dsh-web on :$PORT (repo: $REPO_DIR)..."
    local port_args=()
    if [[ "$PORT" != "3080" ]]; then
        port_args+=(--port "$PORT")
    fi
    systemd-run --user --unit="$UNIT" \
        --property=Restart=on-failure \
        --property=RestartSec=5 \
        --property=Type=simple \
        --working-directory="$REPO_DIR" \
        --setenv=HOME="$HOME" \
        --setenv=PATH="$HOME/.npm-global/bin:/usr/local/bin:/usr/bin:/bin" \
        --collect \
        "$PNPM_BIN" dsh web --no-open "${port_args[@]}"
    wait_http "http://127.0.0.1:$PORT" "dsh web"
}

stop() {
    if ! is_running; then
        warn "dsh-web is not running"
        return
    fi
    info "Stopping dsh-web..."
    systemctl --user stop "$UNIT"
    ok "dsh-web stopped"
}

status() {
    if is_running; then
        local pid
        pid="$(systemctl --user show -p MainPID --value "$UNIT" 2>/dev/null || echo '?')"
        ok "dsh-web running (PID $pid) at http://127.0.0.1:$PORT"
    else
        warn "dsh-web is not running (start it: $0 start)"
    fi
}

logs() {
    local follow="" lines=50
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f|--follow) follow="-f" ;;
            *) lines="$1" ;;
        esac
        shift
    done
    journalctl --user -u "$UNIT" -n "$lines" $follow
}

case "${1:-}" in
    start)   start ;;
    stop)    stop ;;
    restart) stop; sleep 1; start ;;
    status)  status ;;
    logs)    shift; logs "$@" ;;
    *) fail "Usage: $0 {start|stop|restart|status|logs [-f] [N]}" ;;
esac
