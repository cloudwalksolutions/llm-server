#!/usr/bin/env bash
# Common utilities for llama-server scripts

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

_cfg_err() { echo -e "${RED}Config error:${NC} $*" >&2; }

# yq prints the literal string "null" for a missing key, which would otherwise
# reach the llama-server CLI as `-c null`.
_require_int() {
    local name="$1" value="$2"
    if [[ "$value" == "null" || -z "$value" ]]; then
        _cfg_err "$name is not set"
        return 1
    fi
    if [[ ! "$value" =~ ^[0-9]+$ ]] || ((value <= 0)); then
        _cfg_err "$name must be a positive integer (got '$value')"
        return 1
    fi
}

_require_enum() {
    local name="$1" value="$2" allowed=" ${*:3} "
    if [[ "$allowed" != *" $value "* ]]; then
        _cfg_err "$name must be one of:${*:3} (got '$value')"
        return 1
    fi
}

# Load YAML config and export as environment variables
load_config() {
    local config_file="${1:-config/llama.yaml}"

    if [[ ! -f "$config_file" ]]; then
        _cfg_err "$config_file not found"
        echo "Run 'make setup' to create configuration" >&2
        return 1
    fi
    if ! command -v yq >/dev/null 2>&1; then
        _cfg_err "yq is not installed"
        return 1
    fi

    REMOTE_HOST=$(yq '.remote.host' "$config_file")
    REMOTE_USER=$(yq '.remote.user' "$config_file")

    RUNTIME_ENGINE=$(yq '.runtime.engine' "$config_file")
    RUNTIME_GPU=$(yq '.runtime.gpu' "$config_file")

    PARALLEL_SLOTS=$(yq '.llama.parallel_slots' "$config_file")
    CONTEXT_PER_REQUEST=$(yq '.llama.context_per_request' "$config_file")
    KV_UNIFIED=$(yq '.llama.kv_unified' "$config_file")
    BATCH_SIZE=$(yq '.llama.batch_size' "$config_file")
    UBATCH_SIZE=$(yq '.llama.ubatch_size' "$config_file")
    THREADS_GEN=$(yq '.llama.threads_gen' "$config_file")
    THREADS_BATCH=$(yq '.llama.threads_batch' "$config_file")
    THREADS_HTTP=$(yq '.llama.threads_http' "$config_file")
    CACHE_REUSE=$(yq '.llama.cache_reuse' "$config_file")
    CACHE_TYPE_K=$(yq '.llama.cache_type_k' "$config_file")
    CACHE_TYPE_V=$(yq '.llama.cache_type_v' "$config_file")
    FLASH_ATTN=$(yq '.llama.flash_attn' "$config_file")
    DRAFT_MAX=$(yq '.llama.draft_max' "$config_file")
    # yq renders an empty string as '""'; normalise both that and "null" away
    DRAFT_MODEL=$(yq '.llama.draft_model' "$config_file")
    DRAFT_MODEL="${DRAFT_MODEL//\"/}"
    [[ "$DRAFT_MODEL" == "null" ]] && DRAFT_MODEL=""

    # The old key meant a TOTAL that llama.cpp silently divided by the slot
    # count. Refuse to guess which one the user meant.
    local legacy
    legacy=$(yq '.llama.context_size' "$config_file")
    if [[ "$CONTEXT_PER_REQUEST" == "null" && "$legacy" != "null" ]]; then
        _cfg_err "'context_size' is no longer supported; use 'context_per_request'"
        echo "  context_size was a TOTAL divided across parallel_slots." >&2
        echo "  context_per_request is what a single request actually gets." >&2
        echo "  Equivalent of context_size: $legacy with $PARALLEL_SLOTS slots" \
             "is context_per_request: $((legacy / ${PARALLEL_SLOTS:-1}))" >&2
        return 1
    fi

    _require_int "llama.parallel_slots" "$PARALLEL_SLOTS" || return 1
    _require_int "llama.context_per_request" "$CONTEXT_PER_REQUEST" || return 1
    _require_int "llama.batch_size" "$BATCH_SIZE" || return 1
    _require_int "llama.ubatch_size" "$UBATCH_SIZE" || return 1
    _require_int "llama.threads_gen" "$THREADS_GEN" || return 1
    _require_int "llama.threads_batch" "$THREADS_BATCH" || return 1
    _require_int "llama.threads_http" "$THREADS_HTTP" || return 1
    _require_int "llama.cache_reuse" "$CACHE_REUSE" || return 1
    _require_int "llama.draft_max" "$DRAFT_MAX" || return 1
    _require_enum "llama.kv_unified" "$KV_UNIFIED" true false || return 1
    _require_enum "llama.flash_attn" "$FLASH_ATTN" true false || return 1
    _require_enum "runtime.engine" "$RUNTIME_ENGINE" podman docker || return 1
    _require_enum "runtime.gpu" "$RUNTIME_GPU" amd nvidia || return 1

    if ((UBATCH_SIZE > BATCH_SIZE)); then
        _cfg_err "ubatch_size ($UBATCH_SIZE) must not exceed batch_size ($BATCH_SIZE)"
        return 1
    fi
    # Asymmetric K/V types silently fall back to CPU attention: 25-45x slower.
    if [[ "$CACHE_TYPE_K" != "$CACHE_TYPE_V" ]]; then
        _cfg_err "cache_type_k ($CACHE_TYPE_K) must equal cache_type_v ($CACHE_TYPE_V)"
        return 1
    fi

    # llama.cpp refuses to create a context with a quantized V cache unless
    # flash attention is on, and with no -fa flag it defaults to 'auto' and
    # force-enables FA anyway. Either way flash_attn:false is not honoured.
    if [[ "$FLASH_ATTN" == "false" && "$CACHE_TYPE_V" != "f16" && "$CACHE_TYPE_V" != "f32" && "$CACHE_TYPE_V" != "bf16" ]]; then
        _cfg_err "cache_type_v ($CACHE_TYPE_V) is quantized, which requires flash_attn: true"
        echo "  llama.cpp: 'quantized V cache was requested, but this requires Flash Attention'." >&2
        echo "  Set cache_type_k/v to f16, or set flash_attn: true." >&2
        return 1
    fi

    # Quantizing the target model's KV cache is reported to collapse draft
    # acceptance, which negates the speedup. Warn rather than block.
    if [[ -n "$DRAFT_MODEL" && "$CACHE_TYPE_K" != "f16" ]]; then
        echo -e "${YELLOW}Warning:${NC} draft_model with a quantized KV cache ($CACHE_TYPE_K)" >&2
        echo "  can collapse draft acceptance. Consider f16 while speculative decoding." >&2
    fi

    # llama.cpp: n_ctx_seq = kv_unified ? n_ctx : PAD256(n_ctx / n_seq_max)
    if [[ "$KV_UNIFIED" == "true" ]]; then
        TOTAL_CONTEXT="$CONTEXT_PER_REQUEST"
    else
        TOTAL_CONTEXT=$((CONTEXT_PER_REQUEST * PARALLEL_SLOTS))
    fi

    if [[ -f .env ]]; then
        # shellcheck disable=SC1091
        source .env
    fi

    # Not fatal: offline work (rendering, validation) needs no credentials.
    # test_ssh and remote_exec fail loudly if they're actually needed.
    if _is_local_host; then
        SSH_AUTH="local"
    elif [[ -n "${SSH_KEY:-}" ]]; then
        SSH_AUTH="key"
        SSH_KEY="${SSH_KEY/#\~/$HOME}"
    elif [[ -n "${SSH_PASS:-}" ]]; then
        SSH_AUTH="password"
    else
        SSH_AUTH="none"
    fi

    export REMOTE_HOST REMOTE_USER SSH_AUTH SSH_KEY SSH_PASS
    export RUNTIME_ENGINE RUNTIME_GPU
    export PARALLEL_SLOTS BATCH_SIZE UBATCH_SIZE
    export THREADS_GEN THREADS_BATCH THREADS_HTTP
    export CACHE_REUSE CACHE_TYPE_K CACHE_TYPE_V
    export CONTEXT_PER_REQUEST KV_UNIFIED TOTAL_CONTEXT
    export FLASH_ATTN DRAFT_MODEL DRAFT_MAX
}

# True if REMOTE_HOST is this machine (no SSH needed)
_is_local_host() {
    [[ "$REMOTE_HOST" == "localhost" || "$REMOTE_HOST" == "127.0.0.1" || "$REMOTE_HOST" == "$(hostname)" ]] && return 0
    hostname -I 2>/dev/null | tr ' ' '\n' | grep -qx "$REMOTE_HOST"
}

# SSH command as an argv array, so nothing goes through eval
_ssh_argv() {
    if [[ "$SSH_AUTH" == "key" ]]; then
        printf '%s\0' ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no
    else
        printf '%s\0' sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no
    fi
}

_ssh_run() {
    local -a argv=()
    mapfile -d '' -t argv < <(_ssh_argv)
    "${argv[@]}" "$@"
}

_no_auth() {
    _cfg_err "No SSH authentication configured for $REMOTE_USER@$REMOTE_HOST"
    echo "Set SSH_KEY or SSH_PASS in .env" >&2
}

# Test SSH connection
test_ssh() {
    case "$SSH_AUTH" in
        local) return 0 ;;
        none)  _no_auth; return 1 ;;
        *)     _ssh_run -o ConnectTimeout=5 "$REMOTE_USER@$REMOTE_HOST" true 2>/dev/null ;;
    esac
}

# Execute command on remote server
remote_exec() {
    case "$SSH_AUTH" in
        local) bash -c "$*"; return ;;
        none)  _no_auth; return 1 ;;
        *)     _ssh_run "$REMOTE_USER@$REMOTE_HOST" "$*" ;;
    esac
}

# Execute command with sudo on remote server
remote_exec_sudo() {
    if [[ "$SSH_AUTH" == "none" ]]; then
        _no_auth
        return 1
    fi
    if [[ "$SSH_AUTH" == "local" ]]; then
        if [[ -n "${SSH_PASS:-}" ]]; then
            printf '%s\n' "$SSH_PASS" | sudo -S bash -c "$*"
        else
            sudo bash -c "$*"
        fi
    elif [[ "$SSH_AUTH" == "password" ]]; then
        _ssh_run "$REMOTE_USER@$REMOTE_HOST" "printf '%s\n' '$SSH_PASS' | sudo -S bash -c $(_shq "$*")"
    else
        _ssh_run "$REMOTE_USER@$REMOTE_HOST" "sudo bash -c $(_shq "$*")"
    fi
}

# Single-quote a string for safe interpolation into a remote shell
_shq() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

# Read a key from the remote /etc/llama-server.conf.
# `grep | cut || echo default` can never work: the pipeline exits with cut's
# status, which is always 0. Check for emptiness explicitly instead.
remote_conf_value() {
    local key="$1" default="${2:-}" value=""
    value=$(remote_exec "grep '^$key=' /etc/llama-server.conf 2>/dev/null | cut -d= -f2-" 2>/dev/null) || value=""
    value="${value%$'\r'}"
    if [[ -z "$value" ]]; then
        printf '%s' "$default"
    else
        printf '%s' "$value"
    fi
}

# Pretty print configuration
print_config() {
    echo -e "${YELLOW}Target:${NC} $REMOTE_USER@$REMOTE_HOST ($RUNTIME_ENGINE/$RUNTIME_GPU)"
    echo -e "${YELLOW}Context:${NC} $CONTEXT_PER_REQUEST per request × $PARALLEL_SLOTS slots = $TOTAL_CONTEXT total"
    echo -e "${YELLOW}KV cache:${NC} $CACHE_TYPE_K/$CACHE_TYPE_V, unified=$KV_UNIFIED"
    echo -e "${YELLOW}Batching:${NC} $BATCH_SIZE logical / $UBATCH_SIZE physical"
    echo -e "${YELLOW}Threading:${NC} $THREADS_GEN gen / $THREADS_BATCH batch / $THREADS_HTTP HTTP"
    echo -e "${YELLOW}Caching:${NC} $CACHE_REUSE token threshold"
    echo -e "${YELLOW}Flash attn:${NC} $FLASH_ATTN"
    echo -e "${YELLOW}Draft model:${NC} ${DRAFT_MODEL:-none} (max $DRAFT_MAX tokens)"
}
