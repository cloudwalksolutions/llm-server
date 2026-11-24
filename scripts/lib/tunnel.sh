#!/usr/bin/env bash

TUNNEL_CONFIG=/etc/cloudflared/config.yml

_require_host() {
    _require_match "$1 in the env file" "${!1:-}" '^[a-z0-9][a-z0-9.-]*\.[a-z]+$'
}

render_tunnel_config() {
    local tunnel_id="$1" credentials="$2" route
    printf 'tunnel: %s\ncredentials-file: %s\ningress:\n' "$tunnel_id" "$credentials"
    for route in "${@:3}"; do
        printf '  - hostname: %s\n    service: %s\n' "${route%%=*}" "${route#*=}"
    done
    printf '  - service: http_status:404\n'
}
