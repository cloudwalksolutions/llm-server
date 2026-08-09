#!/usr/bin/env bash
# Operate on the target's per-model llama-server instances.
#
# This file used to drive a single `llama-server` unit reading
# /etc/llama-server.conf. That layout does not exist on a migrated target — it
# runs llama-server@<name>.service per model, each with its own conf under
# <instances_dir> — so every one of these commands was silently operating on
# nothing while `make help` advertised them as working.
#
# Each command takes an optional instance name and otherwise applies to every
# instance in config/llama.yaml:
#   ./scripts/server-utils.sh show_status
#   ./scripts/server-utils.sh restart_server qwen3-14b
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

load_config || exit 1

# Resolve the instance list for a command into the TARGETS array: an explicit
# name, or all of them.
#
# Deliberately an array rather than a `while read` over a process substitution:
# ssh inherits stdin and swallows the rest of the list, so a loop written that
# way silently operates on only the first instance.
TARGETS=()
_targets() {
    TARGETS=()
    if [[ -n "${1:-}" ]]; then
        local n found=0
        for n in "${INSTANCE_NAMES[@]}"; do
            [[ "$n" == "$1" ]] && found=1
        done
        if ((found == 0)); then
            echo -e "${RED}no such instance: $1${NC}" >&2
            echo "Known: ${INSTANCE_NAMES[*]}" >&2
            return 1
        fi
        TARGETS=("$1")
    else
        TARGETS=("${INSTANCE_NAMES[@]}")
    fi
}

_conf_of()  { printf '%s/%s.conf' "$INSTANCES_DIR" "$1"; }
_unit_of()  { printf 'llama-server@%s' "$1"; }

show_config() {
    echo -e "${BLUE}⚙️  Remote Server Configuration${NC}"
    echo -e "${BLUE}===============================${NC}\n"
    echo -e "${YELLOW}🔌 Connection:${NC}"
    echo -e "  Host: $REMOTE_HOST"
    echo -e "  User: $REMOTE_USER"
    echo -e "  Instances dir: $INSTANCES_DIR\n"

    _targets "${1:-}" || return 1
    local name
    for name in "${TARGETS[@]}"; do
        echo -e "${YELLOW}📝 $name${NC} ($(_conf_of "$name"))"
        # The key is redacted rather than omitted: seeing that it is SET matters
        # when debugging a 401, seeing its value never does.
        remote_exec "sed 's/^LLAMA_API_KEY=.*/LLAMA_API_KEY=<redacted>/' $(_conf_of "$name") 2>/dev/null" \
            | sed 's/^/  /' || echo "  ❌ Unable to read config"
        echo ""
    done
}

# One instance's runtime picture, all of it read from the server rather than
# inferred from config.
_status_one() {
    local name="$1" unit conf key port props slots metrics pid
    unit=$(_unit_of "$name")
    conf=$(_conf_of "$name")

    echo -e "${YELLOW}▸ $name${NC}"
    printf '  unit:     %s (%s, %s)\n' \
        "$unit" \
        "$(remote_exec "systemctl is-active $unit" 2>/dev/null || echo unknown)" \
        "$(remote_exec "systemctl is-enabled $unit" 2>/dev/null || echo unknown)"

    # Restart count is the tell for a crash loop that a bare is-active hides:
    # Restart=always means a looping unit reports "active" between attempts.
    printf '  restarts: %s\n' \
        "$(remote_exec "systemctl show -p NRestarts --value $unit" 2>/dev/null || echo '?')"

    # remote_conf_value takes (file, key, default). Passing the key as the first
    # argument — as this script used to — reads a file named LLAMA_API_KEY, which
    # never exists, so the key was always empty and every metric below was
    # unreachable.
    key=$(remote_conf_value "$conf" LLAMA_API_KEY)
    port=$(remote_conf_value "$conf" LLAMA_PORT)
    if [[ -z "$port" ]]; then
        echo -e "  ${RED}no LLAMA_PORT in $conf${NC}\n"
        return
    fi

    props=$(remote_exec "curl -sf --max-time 10 -H 'Authorization: Bearer $key' http://127.0.0.1:$port/props" 2>/dev/null || echo "")
    if [[ -n "$props" ]]; then
        printf '  build:    %s\n' "$(jq -r '.build_info // "?"' <<<"$props")"
        printf '  window:   %s tokens/request across %s slots\n' \
            "$(jq -r '.default_generation_settings.n_ctx // "?"' <<<"$props")" \
            "$(jq -r '.total_slots // "?"' <<<"$props")"
    else
        echo -e "  ${RED}/props unreachable on 127.0.0.1:$port${NC}"
    fi

    slots=$(remote_exec "curl -sf --max-time 10 -H 'Authorization: Bearer $key' http://127.0.0.1:$port/slots" 2>/dev/null || echo "")
    if [[ -n "$slots" ]] && jq -e 'type == "array"' <<<"$slots" >/dev/null 2>&1; then
        printf '  slots:    %s total, %s processing\n' \
            "$(jq -r 'length' <<<"$slots")" \
            "$(jq -r '[.[] | select(.is_processing)] | length' <<<"$slots")"
    fi

    metrics=$(remote_exec "curl -sf --max-time 10 -H 'Authorization: Bearer $key' http://127.0.0.1:$port/metrics" 2>/dev/null || echo "")
    if [[ -n "$metrics" ]]; then
        _m() { grep -m1 "^llamacpp:$1 " <<<"$metrics" | awk '{print $2}'; }
        printf '  tokens:   %s prompt, %s generated\n' "$(_m prompt_tokens_total)" "$(_m tokens_predicted_total)"
        printf '  rate:     %s prompt t/s, %s gen t/s\n' "$(_m prompt_tokens_seconds)" "$(_m predicted_tokens_seconds)"
        # Non-zero deferred means requests are queueing for a free slot — the
        # number to watch after changing parallel_slots.
        printf '  queue:    %s processing, %s deferred\n' "$(_m requests_processing)" "$(_m requests_deferred)"
        # There is no kv_cache_usage_ratio metric: it was removed upstream and
        # the request to restore it was closed as not-planned (llama.cpp #23632).
        # n_tokens_max is the high-water mark of context actually observed, which
        # is the closest available signal for context pressure.
        printf '  ctx peak: %s tokens seen (of %s/request)\n' \
            "$(_m n_tokens_max)" "$(jq -r '.default_generation_settings.n_ctx // "?"' <<<"${props:-\{\}}" 2>/dev/null || echo '?')"
        printf '  batching: %s busy slots per decode over %s decodes\n' \
            "$(_m n_busy_slots_per_decode)" "$(_m n_decode_total)"
    else
        echo -e "  ${YELLOW}/metrics unreachable (is --metrics still in the unit?)${NC}"
    fi

    # flash_attn: false does not mean flash attention is off — it only omits -fa,
    # leaving llama.cpp on `auto`. The resolved value is a runtime decision and
    # the journal is the only place it is stated, so surface it here instead of
    # letting the config imply the wrong thing.
    printf '  flash-at: %s\n' \
        "$(remote_exec "journalctl -u $unit --no-pager 2>/dev/null | grep -oE 'Flash Attention was auto, set to [a-z]+' | tail -1" 2>/dev/null \
            | sed 's/Flash Attention was auto, set to /auto -> /' || echo '?')"
    echo ""
}

show_status() {
    echo -e "${BLUE}🖥️  LLM Server Status${NC}"
    echo -e "${BLUE}===================${NC}"
    echo -e "  $REMOTE_USER@$REMOTE_HOST ($RUNTIME_ENGINE/$RUNTIME_GPU)\n"
    _targets "${1:-}" || return 1
    local name
    for name in "${TARGETS[@]}"; do
        _status_one "$name"
    done
}

ssh_in() {
    if [[ "$SSH_AUTH" == "local" ]]; then
        echo -e "${YELLOW}Target is this machine — no SSH needed.${NC}"
        return 0
    fi
    echo -e "${BLUE}SSH into $REMOTE_USER@$REMOTE_HOST...${NC}"
    _ssh_run -t "$REMOTE_USER@$REMOTE_HOST"
}

show_logs() {
    _targets "${1:-}" || return 1
    local name
    for name in "${TARGETS[@]}"; do
        echo -e "${YELLOW}▸ $(_unit_of "$name")${NC}"
        remote_exec "journalctl -u $(_unit_of "$name") -n 50 --no-pager" || true
        echo ""
    done
}

follow_logs() {
    _targets "${1:-}" || return 1
    local -a units=()
    local name
    for name in "${TARGETS[@]}"; do
        units+=("-u" "$(_unit_of "$name")")
    done
    echo -e "${BLUE}following ${#units[@]} unit(s) — Ctrl-C to stop${NC}"
    remote_exec "journalctl ${units[*]} -f"
}

_service_ctl() {
    local action="$1" label="$2" only="${3:-}" name unit rc=0
    _targets "$only" || return 1
    for name in "${TARGETS[@]}"; do
        unit=$(_unit_of "$name")
        echo -e "${BLUE}${label} $unit...${NC}"
        if remote_exec_sudo "systemctl $action $unit"; then
            printf '  %s / %s\n' \
                "$(remote_exec "systemctl is-active $unit" 2>/dev/null || echo unknown)" \
                "$(remote_exec "systemctl is-enabled $unit" 2>/dev/null || echo unknown)"
        else
            echo -e "  ${RED}failed to $action $unit${NC}" >&2
            rc=1
        fi
    done
    return $rc
}

start_server()   { _service_ctl "start"          "▶️  Starting"            "${1:-}"; }
stop_server()    { _service_ctl "stop"           "⏹️  Stopping"            "${1:-}"; }
restart_server() { _service_ctl "restart"        "🔄 Restarting"          "${1:-}"; }
enable_server()  { _service_ctl "enable --now"   "▶️  Enabling + starting" "${1:-}"; }
disable_server() { _service_ctl "disable --now"  "⏹️  Disabling + stopping" "${1:-}"; }

if [[ $# -eq 0 ]]; then
    echo "Usage: $0 <command> [instance]"
    echo "  show_config | show_status | show_logs | follow_logs | ssh_in"
    echo "  start_server | stop_server | restart_server | enable_server | disable_server"
    echo ""
    echo "Instances: ${INSTANCE_NAMES[*]}"
    exit 1
fi

# Guard the dispatch so a mistyped command fails loudly instead of as a bare
# "command not found" with a zero exit status.
declare -F "$1" >/dev/null || { echo -e "${RED}no such command: $1${NC}" >&2; exit 2; }
"$@"
