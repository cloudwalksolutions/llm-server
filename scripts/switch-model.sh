#!/usr/bin/env bash
# Change which model file an instance serves.
# Usage: ./scripts/switch-model.sh <model-filename> [instance]
#
# This only validates and points at the real mechanism. The instance -> model
# mapping lives in config/llama.yaml so it stays under review and in git;
# editing the target directly is what let the deployed config drift before.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

MODEL_FILE="${1:-}"
INSTANCE="${2:-}"
MODELS_DIR="/opt/llm/models"

load_config "${LLAMA_CONFIG:-config/llama.yaml}" || exit 1

if [[ -z "$MODEL_FILE" ]]; then
    echo "Usage: $0 <model-filename> [instance]"
    echo ""
    echo "Instances: ${INSTANCE_NAMES[*]}"
    echo "Run 'make list-models' to see what's available."
    exit 1
fi

if [[ -z "$INSTANCE" ]]; then
    if ((${#INSTANCE_NAMES[@]} == 1)); then
        INSTANCE="${INSTANCE_NAMES[0]}"
    else
        echo -e "${RED}Target serves ${#INSTANCE_NAMES[@]} instances — name one.${NC}" >&2
        echo "Usage: $0 $MODEL_FILE <instance>" >&2
        echo "Instances: ${INSTANCE_NAMES[*]}" >&2
        exit 1
    fi
fi

matched=0
for n in "${INSTANCE_NAMES[@]}"; do [[ "$n" == "$INSTANCE" ]] && matched=1; done
if ((matched == 0)); then
    echo -e "${RED}Unknown instance '$INSTANCE'.${NC}" >&2
    echo "Instances: ${INSTANCE_NAMES[*]}" >&2
    exit 1
fi

test_ssh || { echo -e "${RED}Cannot reach target${NC}" >&2; exit 1; }

if ! remote_exec "test -f '$MODELS_DIR/$MODEL_FILE'"; then
    echo -e "${RED}Model not found on target: $MODELS_DIR/$MODEL_FILE${NC}" >&2
    echo "Download it: make add-model REPO=<hf-repo> MODEL=$MODEL_FILE" >&2
    exit 1
fi

load_instance "$INSTANCE" || exit 1
if [[ "$INST_MODEL_FILE" == "$MODEL_FILE" ]]; then
    echo -e "${GREEN}$INSTANCE already serves $MODEL_FILE${NC}"
    exit 0
fi

echo -e "${YELLOW}$INSTANCE currently serves:${NC} $INST_MODEL_FILE"
echo -e "${YELLOW}Model exists on target:${NC}   $MODEL_FILE"
echo ""
echo "To switch, set it in config/llama.yaml so the change is reviewable:"
echo ""
echo -e "  ${BLUE}instances:"
echo -e "    $INSTANCE:"
echo -e "      model_file: $MODEL_FILE${NC}"
echo ""
echo -e "then: ${BLUE}make deploy-dry${NC} && ${BLUE}make deploy${NC}"
echo ""
echo "Context sizing is per-model — check context_per_request still suits the new one."
