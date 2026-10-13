#!/usr/bin/env bash
# Usage: ./scripts/add-model.sh <hf-repo> <model-filename> [revision]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

REPO="${1:-}"
MODEL_FILE="${2:-}"
REVISION="${3:-main}"

if [[ -z "$REPO" || -z "$MODEL_FILE" ]]; then
    echo "Usage: $0 <hf-repo> <model-filename> [revision]"
    echo ""
    echo "Examples:"
    echo "  $0 unsloth/Qwen3.8-27B-GGUF Qwen3.8-27B-Q8_0.gguf"
    echo "  $0 unsloth/Qwen3.8-27B-GGUF MTP/mtp-Qwen3.8-27B-Q4_0.gguf"
    exit 1
fi

echo -e "${CYAN}[1/5]${NC} Config loaded, connecting to remote..."
load_config || exit 1
test_ssh || { echo -e "${RED}Connection failed${NC}"; exit 1; }

echo -e "${CYAN}[2/5]${NC} Resolving $REPO@$REVISION..."
API="https://huggingface.co/api/models/$REPO"
COMMIT=$(curl -sf "$API/revision/$REVISION" | jq -r '.sha // empty')
[[ -n "$COMMIT" ]] || { echo -e "${RED}Cannot resolve $REPO@$REVISION${NC}"; exit 1; }
EXPECTED=$(curl -sf "$API/tree/$COMMIT?recursive=true" \
    | jq -r --arg p "$MODEL_FILE" '.[] | select(.path == $p) | .lfs.oid // empty')
[[ -n "$EXPECTED" ]] || { echo -e "${RED}$MODEL_FILE has no published sha256 at $COMMIT${NC}"; exit 1; }
echo "  commit $COMMIT, sha256 $EXPECTED"

if ! remote_exec "command -v hf >/dev/null 2>&1"; then
    echo -e "${RED}Error: 'hf' CLI not found on remote${NC}"
    echo "Run the install script to set up the remote server first"
    exit 1
fi

if ! remote_exec "test -f '$MODELS_DIR/$MODEL_FILE'"; then
    echo -e "${CYAN}[3/5]${NC} Downloading $MODEL_FILE..."
    remote_exec "HF_HUB_CACHE='$MODELS_DIR/.cache' hf download '$REPO' '$MODEL_FILE' --revision '$COMMIT' --local-dir '$MODELS_DIR'"
    remote_exec "rm -rf '$MODELS_DIR/.cache'"
else
    echo -e "${CYAN}[3/5]${NC} $MODEL_FILE is already on the target; checking it"
fi

echo -e "${CYAN}[4/5]${NC} Checking sha256..."
ACTUAL=$(remote_exec "sha256sum '$MODELS_DIR/$MODEL_FILE'" | cut -d' ' -f1)
if [[ "$ACTUAL" != "$EXPECTED" ]]; then
    echo -e "${RED}sha256 mismatch for $MODEL_FILE: got $ACTUAL, want $EXPECTED. Not using it.${NC}"
    exit 1
fi

SIZE=$(remote_exec "du -h '$MODELS_DIR/$MODEL_FILE' | cut -f1")
echo -e "${CYAN}[5/5]${NC} ${GREEN}$MODEL_FILE ($SIZE) matches $REPO@${COMMIT:0:12}${NC}"
