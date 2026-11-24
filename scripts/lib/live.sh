#!/usr/bin/env bash

cmdline_arg() {
    awk -v flag="$1" '{ for (i = 1; i < NF; i++) if ($i == flag) { print $(i + 1); exit } }' <<<"$2"
}

live_cmdline() {
    local pid
    pid=$(remote_exec "systemctl show -p MainPID --value $1" 2>/dev/null | tr -d '\r')
    [[ "$pid" =~ ^[0-9]+$ ]] && ((pid != 0)) || return 0
    remote_exec "tr '\\0' ' ' < /proc/$pid/cmdline 2>/dev/null" || true
}

flash_attn_state() {
    local fa v
    fa=$(cmdline_arg -fa "$1")
    v=$(cmdline_arg --cache-type-v "$1")
    if [[ -n "$fa" ]]; then
        echo "$fa (-fa $fa)"
    elif [[ -n "$v" && ! "$v" =~ ^(f32|f16|bf16)$ ]]; then
        echo "enabled (llama.cpp will not run a $v V cache without it)"
    else
        echo "auto (resolved value not logged)"
    fi
}
