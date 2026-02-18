#!/usr/bin/env bash
# Switch the active model on the remote LLM server
# Usage: ./scripts/switch-model.sh <model-filename>
# Example: ./scripts/switch-model.sh Qwen3-14B-Q4_K_M.gguf
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

MODEL_FILE="${1:-}"
MODELS_DIR="/opt/llm/models"
CONF_FILE="/etc/llama-server.conf"

if [[ -z "$MODEL_FILE" ]]; then
    echo "Usage: $0 <model-filename>"
    echo ""
    echo "Run 'make list-models' to see available models"
    exit 1
fi

echo -e "${CYAN}[1/4]${NC} Connecting to remote..."
load_config || exit 1
test_ssh || { echo -e "${RED}Connection failed${NC}"; exit 1; }

echo -e "${CYAN}[2/4]${NC} Validating model exists on remote..."
if ! remote_exec "test -f '$MODELS_DIR/$MODEL_FILE'"; then
    echo -e "${RED}Error: Model not found: $MODEL_FILE${NC}"
    echo ""
    echo "Available models:"
    remote_exec "for f in $MODELS_DIR/*.gguf; do [[ -f \"\$f\" ]] && basename \"\$f\"; done 2>/dev/null" || echo "  (none)"
    echo ""
    echo "Download with: make add-model REPO=<hf-repo> MODEL=$MODEL_FILE"
    exit 1
fi

CURRENT_MODEL=$(remote_exec "grep '^MODEL_FILE=' $CONF_FILE 2>/dev/null | cut -d= -f2" || echo "")
if [[ "$CURRENT_MODEL" == "$MODEL_FILE" ]]; then
    echo -e "${YELLOW}Already active: $MODEL_FILE${NC}"
    exit 0
fi

echo -e "${CYAN}[3/4]${NC} Switching from '$CURRENT_MODEL' to '$MODEL_FILE'..."
remote_exec_sudo "sed -i 's|^MODEL_FILE=.*|MODEL_FILE=$MODEL_FILE|' $CONF_FILE"
remote_exec_sudo "systemctl restart llama-server"

echo -e "${CYAN}[4/4]${NC} Waiting for health check..."
for i in {1..60}; do
    if remote_exec "curl -sf http://localhost:8080/health > /dev/null 2>&1"; then
        echo -e "${GREEN}Switched to: $MODEL_FILE${NC}"
        echo ""
        echo "Next: make test-models | make test | make status"
        exit 0
    fi
    sleep 1
done

echo -e "${RED}Health check timeout. Check logs: make logs${NC}"
exit 1
