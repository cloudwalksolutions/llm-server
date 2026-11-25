#!/usr/bin/env bash

COMFYUI_TEMPLATES="$(dirname "${BASH_SOURCE[0]}")/../../templates"
COMFYUI_UNIT_PATH=/etc/systemd/system/comfyui.service
COMFYUI_PROXY_PATH=/etc/nginx/conf.d/comfyui-proxy.conf
COMFYUI_KEY_MAP_PATH=/etc/nginx/comfyui-api-key.map
COMFYUI_MCP_KEY_MAP_PATH=/etc/nginx/comfyui-mcp-key.map
COMFYUI_MCP_UNIT_PATH=/etc/systemd/system/comfyui-mcp.service
COMFYUI_MCP_SOURCE="$(dirname "${BASH_SOURCE[0]}")/../../comfyui-mcp"
COMFYUI_MCP_MANIFEST="find . -path ./.venv -prune -o -type f -print | LC_ALL=C sort | xargs sha256sum"

load_comfyui() {
    COMFYUI_CONFIG="${COMFYUI_CONFIG:-$(dirname "$CONFIG_FILE")/comfyui.yaml}"
    COMFYUI_CONFIGURED=false
    COMFYUI_ENABLED=false
    [[ -f "$COMFYUI_CONFIG" ]] || return 0
    COMFYUI_CONFIGURED=true
    COMFYUI_ENABLED=$(yq '.enabled' "$COMFYUI_CONFIG")
    COMFYUI_PORT=$(yq '.port' "$COMFYUI_CONFIG")
    COMFYUI_API_PORT=$(yq '.api_port' "$COMFYUI_CONFIG")
    COMFYUI_UI_PORT=$(yq '.ui_port' "$COMFYUI_CONFIG")
    COMFYUI_MCP_PORT=$(yq '.mcp_port' "$COMFYUI_CONFIG")
    COMFYUI_IMAGE=$(yq '.container_image' "$COMFYUI_CONFIG")
    COMFYUI_DIR=$(yq '.dir' "$COMFYUI_CONFIG")
    COMFYUI_MCP_DIR="$COMFYUI_DIR/mcp"
    _require_enum "comfyui enabled" "$COMFYUI_ENABLED" true false || return 1
    _require_int "comfyui port" "$COMFYUI_PORT" || return 1
    _require_int "comfyui api_port" "$COMFYUI_API_PORT" || return 1
    _require_int "comfyui ui_port" "$COMFYUI_UI_PORT" || return 1
    _require_int "comfyui mcp_port" "$COMFYUI_MCP_PORT" || return 1
    _require_str "comfyui container_image" "$COMFYUI_IMAGE" || return 1
    _require_no_control_chars "comfyui container_image" "$COMFYUI_IMAGE" || return 1
    _require_safe_path "comfyui dir" "$COMFYUI_DIR" absolute || return 1

    local taken=" 8080 " n p
    for n in "${INSTANCE_NAMES[@]}"; do
        taken+="$(_ivalue "$n" port) "
    done
    for p in "$COMFYUI_PORT" "$COMFYUI_API_PORT" "$COMFYUI_UI_PORT" "$COMFYUI_MCP_PORT"; do
        [[ "$taken" == *" $p "* ]] && { _cfg_err "comfyui port $p is already taken"; return 1; }
        taken+="$p "
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

render_comfyui_unit() {
    local body
    body=$(<"$COMFYUI_TEMPLATES/comfyui.service.in")
    body="${body//@ENGINE_BIN@//usr/bin/$RUNTIME_ENGINE}"
    body="${body//@COMFYUI_DIR@/$COMFYUI_DIR}"
    body="${body//@COMFYUI_PORT@/$COMFYUI_PORT}"
    body="${body//@COMFYUI_IMAGE@/$COMFYUI_IMAGE}"
    printf '%s\n' "$body"
}

render_comfyui_mcp_unit() {
    local body
    body=$(<"$COMFYUI_TEMPLATES/comfyui-mcp.service.in")
    body="${body//@MCP_DIR@/$COMFYUI_MCP_DIR}"
    body="${body//@MCP_PORT@/$COMFYUI_MCP_PORT}"
    body="${body//@COMFYUI_PORT@/$COMFYUI_PORT}"
    body="${body//@API_HOST@/${COMFYUI_API_HOST:-}}"
    printf '%s\n' "$body"
}

stage_comfyui_mcp() {
    local stage="$1"
    chmod 755 "$stage"
    cp "$COMFYUI_MCP_SOURCE/server.py" "$COMFYUI_MCP_SOURCE/viewer.html" "$stage/"
    cp -R "$COMFYUI_MCP_SOURCE/workflows" "$COMFYUI_MCP_SOURCE/fonts" "$stage/"
    uv export --quiet --locked --no-header --no-dev --no-emit-project --format requirements-txt \
        --project "$COMFYUI_MCP_SOURCE" -o "$stage/requirements.txt"
}

render_comfyui_proxy() {
    local body
    body=$(<"$COMFYUI_TEMPLATES/comfyui-proxy.conf.in")
    body="${body//@KEY_MAP@/$COMFYUI_KEY_MAP_PATH}"
    body="${body//@MCP_KEY_MAP@/$COMFYUI_MCP_KEY_MAP_PATH}"
    body="${body//@MCP_PORT@/$COMFYUI_MCP_PORT}"
    body="${body//@API_PORT@/$COMFYUI_API_PORT}"
    body="${body//@UI_PORT@/$COMFYUI_UI_PORT}"
    body="${body//@COMFYUI_PORT@/$COMFYUI_PORT}"
    printf '%s\n' "$body"
}

comfyui_proxy_listening() {
    local listeners
    listeners=$(remote_exec "ss -ltnH" 2>/dev/null)
    grep -q "127.0.0.1:$COMFYUI_API_PORT " <<<"$listeners" && grep -q "127.0.0.1:$COMFYUI_UI_PORT " <<<"$listeners"
}

allow_nginx_ports() {
    local port
    for port in "$@"; do
        remote_exec_sudo "! command -v semanage >/dev/null || semanage port -l | grep -qE '^http_port_t +tcp .*\\b$port\\b' || semanage port -a -t http_port_t -p tcp $port"
    done
}

render_comfyui_key_map() {
    printf '"~^Bearer %s$" 1;\n' "$1"
}
