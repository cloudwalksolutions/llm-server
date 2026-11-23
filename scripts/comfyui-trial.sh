#!/usr/bin/env bash
# Usage: ./scripts/comfyui-trial.sh start|stop
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

load_config "${LLAMA_CONFIG:-config/llama.yaml}" || exit 1
[[ "$COMFYUI_ENABLED" == true ]] || { echo -e "${RED}config has no comfyui: block${NC}" >&2; exit 1; }
test_ssh || { echo -e "${RED}Cannot reach target${NC}" >&2; exit 1; }

wait_for() {
    local what="$1" url="$2" timeout="$3" start
    start=$(date +%s)
    until [[ "$(remote_exec "curl -s -o /dev/null -w '%{http_code}' $url" 2>/dev/null)" == 200 ]]; do
        (($(date +%s) - start < timeout)) || { echo -e "\n${RED}$what did not answer within ${timeout}s${NC}" >&2; return 1; }
        printf '.'
        sleep 5
    done
    echo -e " ${GREEN}$what is up${NC}"
}

case "${1:-}" in
    start)
        echo "Starting ComfyUI; this stops: ${COMFYUI_TRIAL_STOPS[*]:-nothing}"
        remote_exec_sudo "systemctl start comfyui"
        wait_for ComfyUI "http://127.0.0.1:$COMFYUI_PORT/system_stats" 900
        ;;
    stop)
        remote_exec_sudo "systemctl stop comfyui"
        echo -e "  ${GREEN}ComfyUI stopped${NC}"
        for name in "${COMFYUI_TRIAL_STOPS[@]}"; do
            load_instance "$name"
            remote_exec_sudo "systemctl start llama-server@$name"
            wait_for "$name" "http://127.0.0.1:$INST_PORT/health" 600
        done
        ;;
    *) echo "Usage: $0 start|stop" >&2; exit 2 ;;
esac
