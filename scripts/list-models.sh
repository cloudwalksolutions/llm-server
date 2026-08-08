#!/usr/bin/env bash
# List models on the target and which instance serves each.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

MODELS_DIR="/opt/llm/models"

load_config "${LLAMA_CONFIG:-config/llama.yaml}" || exit 1
test_ssh || { echo -e "${RED}Cannot reach target${NC}" >&2; exit 1; }

echo -e "${BLUE}Models on $REMOTE_HOST${NC}\n"

echo -e "${YELLOW}Serving:${NC}"
for name in "${INSTANCE_NAMES[@]}"; do
    load_instance "$name" 2>/dev/null || continue
    state=$(remote_exec "systemctl is-active llama-server@$name" 2>/dev/null || echo unknown)
    printf '  %-16s %-30s :%s  %s\n' "$name" "$INST_MODEL_FILE" "$INST_PORT" "$state"
done

echo -e "\n${YELLOW}Available in $MODELS_DIR:${NC}"
remote_exec "for f in $MODELS_DIR/*.gguf; do [[ -f \"\$f\" ]] && printf '  %-40s %s\n' \"\$(basename \"\$f\")\" \"\$(du -h \"\$f\" | cut -f1)\"; done" 2>/dev/null \
    || echo "  (none)"

echo ""
echo "Clients select a model by its instance name, e.g. {\"model\": \"${INSTANCE_NAMES[0]}\"}"
echo "To change which file an instance serves: edit model_file in config/llama.yaml, then make deploy"
echo "To download another: make add-model REPO=<hf-repo> MODEL=<file.gguf>"
