#!/usr/bin/env bash

load_comfyui() {
    COMFYUI_CONFIG="${COMFYUI_CONFIG:-$(dirname "$CONFIG_FILE")/comfyui.yaml}"
    COMFYUI_CONFIGURED=false
    COMFYUI_ENABLED=false
    [[ -f "$COMFYUI_CONFIG" ]] || return 0
    COMFYUI_CONFIGURED=true
    COMFYUI_ENABLED=$(yq '.enabled' "$COMFYUI_CONFIG")
    COMFYUI_PORT=$(yq '.port' "$COMFYUI_CONFIG")
    COMFYUI_IMAGE=$(yq '.container_image' "$COMFYUI_CONFIG")
    COMFYUI_DIR=$(yq '.dir' "$COMFYUI_CONFIG")
    _require_enum "comfyui enabled" "$COMFYUI_ENABLED" true false || return 1
    _require_int "comfyui port" "$COMFYUI_PORT" || return 1
    _require_str "comfyui container_image" "$COMFYUI_IMAGE" || return 1
    _require_no_control_chars "comfyui container_image" "$COMFYUI_IMAGE" || return 1
    _require_safe_path "comfyui dir" "$COMFYUI_DIR" absolute || return 1

    local n p
    for n in "${INSTANCE_NAMES[@]}"; do
        p=$(_ivalue "$n" port)
        [[ "$p" == "$COMFYUI_PORT" ]] && { _cfg_err "comfyui port $p is also instance $n's port"; return 1; }
    done

    local i count
    count=$(yq '.models // [] | length' "$COMFYUI_CONFIG")
    for ((i = 0; i < count; i++)); do
        _require_comfyui_model "$i" || return 1
    done
}

_require_comfyui_model() {
    local i="$1" p="comfyui models[$1]"
    if [[ "$(yq ".models[$i] | has(\"civitai\")" "$COMFYUI_CONFIG")" == true ]]; then
        _require_int "$p.civitai" "$(yq ".models[$i].civitai" "$COMFYUI_CONFIG")" || return 1
    else
        _require_match "$p.repo" "$(yq ".models[$i].repo" "$COMFYUI_CONFIG")" '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' || return 1
        _require_match "$p.revision" "$(yq ".models[$i].revision" "$COMFYUI_CONFIG")" '^[0-9a-f]{40}$' || return 1
        _require_safe_path "$p.file" "$(yq ".models[$i].file" "$COMFYUI_CONFIG")" relative || return 1
    fi
    _require_match "$p.sha256" "$(yq ".models[$i].sha256" "$COMFYUI_CONFIG")" '^[0-9a-f]{64}$' || return 1
    _require_safe_path "$p.dest" "$(yq ".models[$i].dest" "$COMFYUI_CONFIG")" relative || return 1
}
