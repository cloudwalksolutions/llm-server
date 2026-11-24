#!/usr/bin/env bash
# Usage: ./scripts/comfyui-models.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

load_config "${LLAMA_CONFIG:-config/llama.yaml}" || exit 1
[[ "$COMFYUI_CONFIGURED" == true ]] || { echo -e "${RED}$COMFYUI_CONFIG does not exist${NC}" >&2; exit 1; }
test_ssh || { echo -e "${RED}Cannot reach target${NC}" >&2; exit 1; }
remote_exec "command -v hf >/dev/null 2>&1" \
    || { echo -e "${RED}'hf' CLI not found on the target; run the install script first${NC}" >&2; exit 1; }

STAGING="$COMFYUI_DIR/.staging"

download_from_huggingface() {
    local m="$1" repo revision file
    repo=$(yq "$m.repo" "$COMFYUI_CONFIG")
    revision=$(yq "$m.revision" "$COMFYUI_CONFIG")
    file=$(yq "$m.file" "$COMFYUI_CONFIG")
    echo -e "  ${CYAN}download${NC} $repo@${revision:0:12} $file" >&2
    remote_exec "HF_HUB_CACHE=$(_shq "$STAGING/.cache") hf download $(_shq "$repo") $(_shq "$file") --revision $(_shq "$revision") --local-dir $(_shq "$STAGING") >/dev/null"
    echo "$STAGING/$file"
}

download_from_civitai() {
    local m="$1" version staged
    version=$(yq "$m.civitai" "$COMFYUI_CONFIG")
    staged="$STAGING/civitai-$version"
    echo -e "  ${CYAN}download${NC} civitai model version $version" >&2
    printf '%s' "${CIVITAI_API_TOKEN:+Authorization: Bearer $CIVITAI_API_TOKEN}" \
        | remote_exec "mkdir -p $(_shq "$STAGING") && curl -fsSL -H @- -o $(_shq "$staged") https://civitai.com/api/download/models/$version"
    echo "$staged"
}

count=$(yq '.models | length' "$COMFYUI_CONFIG")
for ((i = 0; i < count; i++)); do
    m=".models[$i]"
    sha256=$(yq "$m.sha256" "$COMFYUI_CONFIG")
    dest="$COMFYUI_DIR/models/$(yq "$m.dest" "$COMFYUI_CONFIG")"

    if [[ "$(remote_exec "sha256sum $(_shq "$dest") 2>/dev/null" | cut -d' ' -f1)" == "$sha256" ]]; then
        echo -e "  ${GREEN}present${NC}  $dest"
        continue
    fi

    if [[ "$(yq "$m | has(\"civitai\")" "$COMFYUI_CONFIG")" == true ]]; then
        staged=$(download_from_civitai "$m")
    else
        staged=$(download_from_huggingface "$m")
    fi
    actual=$(remote_exec "sha256sum $(_shq "$staged")" | cut -d' ' -f1)
    if [[ "$actual" != "$sha256" ]]; then
        remote_exec "rm -f $(_shq "$staged")"
        echo -e "${RED}sha256 mismatch for $dest: got $actual, want $sha256. Not using it.${NC}" >&2
        exit 1
    fi
    remote_exec "mkdir -p $(_shq "$(dirname "$dest")") && mv $(_shq "$staged") $(_shq "$dest")"
    echo -e "  ${GREEN}verified${NC} $dest"
done
remote_exec "rm -rf $(_shq "$STAGING")"
echo -e "${GREEN}Every ComfyUI model matches its pin${NC}"
