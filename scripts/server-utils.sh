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

    # Get API key from remote config
    API_KEY=$(remote_exec "grep LLAMA_API_KEY /etc/llama-server.conf 2>/dev/null | cut -d= -f2" || echo "")

    if [[ -n "$API_KEY" ]]; then
        if remote_exec "curl -sf -H 'Authorization: Bearer $API_KEY' http://localhost:8080/metrics 2>/dev/null" > /tmp/metrics.txt; then
            if grep -qi "llamacpp" /tmp/metrics.txt 2>/dev/null; then
                echo "  Tokens processed: $(grep llamacpp:prompt_tokens_total /tmp/metrics.txt | awk '{print $2}')"
                echo "  Tokens generated: $(grep llamacpp:tokens_predicted_total /tmp/metrics.txt | awk '{print $2}')"
                echo "  ✅ Metrics available"
            else
                echo "  ⚠️  No metrics found"
            fi
            rm -f /tmp/metrics.txt
        else
            echo "  ❌ Unable to fetch metrics"
        fi
    else
        echo "  ⚠️  No API key, skipping metrics"
    fi

    echo ""
}

# Run the requested function
if [[ $# -eq 0 ]]; then
    echo "Usage: $0 {show_config|show_status}"
    exit 1
fi

"$@"
