#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

load_config || exit 1

show_config() {
    echo -e "${BLUE}⚙️  Remote Server Configuration${NC}"
    echo -e "${BLUE}===============================${NC}\n"

    echo -e "${YELLOW}🔌 Connection:${NC}"
    echo -e "  Host: $REMOTE_HOST"
    echo -e "  User: $REMOTE_USER\n"

    echo -e "${YELLOW}📝 Current llama-server config:${NC}"
    remote_exec "cat /etc/llama-server.conf 2>/dev/null" || echo "  ❌ Unable to read config"

    echo ""
}

show_status() {
    echo -e "${BLUE}🖥️  LLM Server Status${NC}"
    echo -e "${BLUE}===================${NC}\n"

    echo -e "${YELLOW}📊 Service Status:${NC}"
    remote_exec "systemctl status llama-server --no-pager -l" || echo "  ❌ Unable to get status"

    echo -e "\n${YELLOW}📈 Metrics:${NC}"

    API_KEY=$(remote_conf_value LLAMA_API_KEY)
    PORT=$(remote_conf_value LLAMA_PORT 8080)

    if [[ -z "$API_KEY" ]]; then
        echo "  ⚠️  No API key, skipping metrics"
        echo ""
        return
    fi

    local metrics
    metrics=$(mktemp)
    if remote_exec "curl -sf -H 'Authorization: Bearer $API_KEY' http://localhost:$PORT/metrics 2>/dev/null" > "$metrics"; then
        if grep -qi "llamacpp" "$metrics" 2>/dev/null; then
            _metric() { grep -m1 "^llamacpp:$1 " "$metrics" | awk '{print $2}'; }
            echo "  Tokens processed:   $(_metric prompt_tokens_total)"
            echo "  Tokens generated:   $(_metric tokens_predicted_total)"
            echo "  Context per slot:   $(_metric n_tokens_max)"
            echo "  Requests active:    $(_metric requests_processing)"
            # Non-zero means requests are queueing for a free slot — the metric
            # to watch after changing parallel_slots.
            echo "  Requests deferred:  $(_metric requests_deferred)"
            echo "  KV cache used:      $(_metric kv_cache_usage_ratio)"
        else
            echo "  ⚠️  No metrics found"
        fi
    else
        echo "  ❌ Unable to fetch metrics"
    fi
    rm -f "$metrics"

    echo ""
}

show_logs() {
    remote_exec "journalctl -u llama-server -n 50 --no-pager"
}

follow_logs() {
    remote_exec "journalctl -u llama-server -f"
}

_service_ctl() {
    local action="$1" label="$2"
    echo -e "${BLUE}${label} llama-server on ${REMOTE_HOST}...${NC}"
    if remote_exec_sudo "systemctl $action llama-server"; then
        echo -e "${GREEN}✅ Done${NC}"
        remote_exec "systemctl is-active llama-server; systemctl is-enabled llama-server" || true
    else
        echo -e "${RED}❌ Failed to $action llama-server${NC}"
        return 1
    fi
}

start_server()   { _service_ctl "start" "▶️  Starting"; }
stop_server()    { _service_ctl "stop" "⏹️  Stopping"; }
restart_server() { _service_ctl "restart" "🔄 Restarting"; }
enable_server()  { _service_ctl "enable --now" "▶️  Enabling + starting"; }
disable_server() { _service_ctl "disable --now" "⏹️  Disabling + stopping"; }

# Run the requested function
if [[ $# -eq 0 ]]; then
    echo "Usage: $0 {show_config|show_status|start_server|stop_server|restart_server|enable_server|disable_server}"
    exit 1
fi

"$@"
