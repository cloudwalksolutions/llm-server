#!/usr/bin/env bash
# Usage: ./scripts/comfyui-models.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

load_config "${LLAMA_CONFIG:-config/llama.yaml}" || exit 1
[[ "$COMFYUI_ENABLED" == true ]] || { echo -e "${RED}config has no comfyui: block${NC}" >&2; exit 1; }
test_ssh || { echo -e "${RED}Cannot reach target${NC}" >&2; exit 1; }
remote_exec "command -v hf >/dev/null 2>&1" \
    || { echo -e "${RED}'hf' CLI not found on the target; run the install script first${NC}" >&2; exit 1; }

STAGING="$COMFYUI_DIR/.staging"
count=$(yq '.comfyui.models | length' "$CONFIG_FILE")
for ((i = 0; i < count; i++)); do
    m=".comfyui.models[$i]"
    repo=$(yq "$m.repo" "$CONFIG_FILE")
    revision=$(yq "$m.revision" "$CONFIG_FILE")
    file=$(yq "$m.file" "$CONFIG_FILE")
    sha256=$(yq "$m.sha256" "$CONFIG_FILE")
    dest="$COMFYUI_DIR/models/$(yq "$m.dest" "$CONFIG_FILE")"

    if [[ "$(remote_exec "sha256sum $(_shq "$dest") 2>/dev/null" | cut -d' ' -f1)" == "$sha256" ]]; then
        echo -e "  ${GREEN}present${NC}  $dest"
        continue
    fi

    echo -e "  ${CYAN}download${NC} $repo@${revision:0:12} $file"
    remote_exec "HF_HUB_CACHE=$(_shq "$STAGING/.cache") hf download $(_shq "$repo") $(_shq "$file") --revision $(_shq "$revision") --local-dir $(_shq "$STAGING") >/dev/null"
    actual=$(remote_exec "sha256sum $(_shq "$STAGING/$file")" | cut -d' ' -f1)
    if [[ "$actual" != "$sha256" ]]; then
        remote_exec "rm -f $(_shq "$STAGING/$file")"
        echo -e "${RED}sha256 mismatch for $file: got $actual, want $sha256. Not using it.${NC}" >&2
        exit 1
    fi
    remote_exec "mkdir -p $(_shq "$(dirname "$dest")") && mv $(_shq "$STAGING/$file") $(_shq "$dest")"
    echo -e "  ${GREEN}verified${NC} $dest"
done
remote_exec "rm -rf $(_shq "$STAGING")"
echo -e "${GREEN}Every ComfyUI model matches its pin${NC}"
