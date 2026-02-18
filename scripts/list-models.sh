#!/usr/bin/env bash
# List available models on the remote LLM server
# Usage: ./scripts/list-models.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

MODELS_DIR="/opt/llm/models"
CONF_FILE="/etc/llama-server.conf"

load_config || exit 1
test_ssh || { echo -e "${RED}Connection failed${NC}"; exit 1; }

CURRENT_MODEL=$(remote_exec "grep '^MODEL_FILE=' $CONF_FILE 2>/dev/null | cut -d= -f2" || echo "")

echo -e "${BLUE}Models on ${REMOTE_HOST}:${NC}"
echo ""

remote_exec "
for f in $MODELS_DIR/*.gguf; do
    [[ -f \"\$f\" ]] || continue
    name=\$(basename \"\$f\")
    size=\$(du -h \"\$f\" | cut -f1)
    if [[ \"\$name\" == \"$CURRENT_MODEL\" ]]; then
        echo \"  * \$name (\$size) [ACTIVE]\"
    else
        echo \"    \$name (\$size)\"
    fi
done
"

echo ""
echo "Commands:"
echo "  make switch-model MODEL=<filename>    Switch active model"
echo "  make add-model REPO=<repo> MODEL=<file>   Download new model"
