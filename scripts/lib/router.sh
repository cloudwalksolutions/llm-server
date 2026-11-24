#!/usr/bin/env bash

router_map_with() {
    jq -c --arg n "$2" --arg b "127.0.0.1:$3" '. + {($n): $b}' <<<"$1"
}

router_map_without() {
    jq -c --arg n "$2" 'del(.[$n])' <<<"$1"
}

router_map_default() {
    jq -c --arg b "127.0.0.1:$2" '. + {_default: $b}' <<<"$1"
}
