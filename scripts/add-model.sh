#!/usr/bin/env bash
# Download a model from HuggingFace to the remote LLM server
# Usage: ./scripts/add-model.sh <hf-repo> <model-filename>
# Example: ./scripts/add-model.sh Qwen/Qwen3-14B-GGUF Qwen3-14B-Q4_K_M.gguf
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

REPO="${1:-}"
MODEL_FILE="${2:-}"
MODELS_DIR="/opt/llm/models"

if [[ -z "$REPO" || -z "$MODEL_FILE" ]]; then
    echo "Usage: $0 <hf-repo> <model-filename>"
    echo ""
    echo "Examples:"
    echo "  $0 Qwen/Qwen3-14B-GGUF Qwen3-14B-Q4_K_M.gguf"
    echo "  $0 bartowski/DeepSeek-R1-Distill-Qwen-14B-GGUF DeepSeek-R1-Distill-Qwen-14B-Q4_K_M.gguf"
    exit 1
fi

echo -e "${CYAN}[1/4]${NC} Config loaded, connecting to remote..."
load_config || exit 1
test_ssh || { echo -e "${RED}Connection failed${NC}"; exit 1; }

echo -e "${CYAN}[2/4]${NC} Checking prerequisites..."
if ! remote_exec "command -v hf >/dev/null 2>&1"; then
    echo -e "${RED}Error: 'hf' CLI not found on remote${NC}"
    echo "Run the install script to set up the remote server first"
    exit 1
fi

if remote_exec "test -f '$MODELS_DIR/$MODEL_FILE'"; then
    SIZE=$(remote_exec "du -h '$MODELS_DIR/$MODEL_FILE' | cut -f1")
    echo -e "${YELLOW}Model already exists: $MODEL_FILE ($SIZE)${NC}"
    echo "Use 'make list-models' to see all available models"
    exit 0
fi

echo -e "${CYAN}[3/4]${NC} Downloading $MODEL_FILE from $REPO..."
echo "  This may take several minutes for large models..."
remote_exec "HF_HUB_CACHE='$MODELS_DIR/.cache' hf download '$REPO' '$MODEL_FILE' --local-dir '$MODELS_DIR'"
remote_exec "rm -rf '$MODELS_DIR/.cache'"

echo -e "${CYAN}[4/4]${NC} Verifying download..."
if remote_exec "test -f '$MODELS_DIR/$MODEL_FILE'"; then
    SIZE=$(remote_exec "du -h '$MODELS_DIR/$MODEL_FILE' | cut -f1")
    echo -e "${GREEN}Downloaded: $MODEL_FILE ($SIZE)${NC}"
    echo ""
    echo "Next steps:"
    echo "  make list-models                    # See all available models"
    echo "  make switch-model MODEL=$MODEL_FILE   # Switch to this model"
else
    echo -e "${RED}Download failed: model file not found${NC}"
    exit 1
fi
