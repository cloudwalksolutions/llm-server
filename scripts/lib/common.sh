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

CONFIG_FILE=""
declare -A _WARNED=()

# Load the global sections and the instance list.
load_config() {
    CONFIG_FILE="${1:-config/llama.yaml}"

    if [[ ! -f "$CONFIG_FILE" ]]; then
        _cfg_err "$CONFIG_FILE not found"
        echo "Run 'make setup' to create configuration" >&2
        return 1
    fi
    if ! command -v yq >/dev/null 2>&1; then
        _cfg_err "yq is not installed"
        return 1
    fi

    REMOTE_HOST=$(yq '.remote.host' "$CONFIG_FILE")
    REMOTE_USER=$(yq '.remote.user' "$CONFIG_FILE")
    RUNTIME_ENGINE=$(yq '.runtime.engine' "$CONFIG_FILE")
    RUNTIME_GPU=$(yq '.runtime.gpu' "$CONFIG_FILE")
    INSTANCES_DIR=$(yq '.runtime.instances_dir // "/opt/llm/instances"' "$CONFIG_FILE")
    ROUTER_MAP=$(yq '.runtime.router_map // "/etc/llama-router/models.json"' "$CONFIG_FILE")

    _require_enum "runtime.engine" "$RUNTIME_ENGINE" podman docker || return 1
    _require_enum "runtime.gpu" "$RUNTIME_GPU" amd nvidia || return 1

    # The old schema was a single flat llama: block. Refuse to guess.
    if [[ "$(yq '.instances' "$CONFIG_FILE")" == "null" ]]; then
        _cfg_err "no 'instances:' block found"
        echo "  This target runs one llama-server per model via llama-server@<name>.service." >&2
        echo "  See config/llama.example.yaml for the schema." >&2
        return 1
    fi

    mapfile -t INSTANCE_NAMES < <(yq -r '.instances | keys | .[]' "$CONFIG_FILE")
    if ((${#INSTANCE_NAMES[@]} == 0)); then
        _cfg_err "'instances:' is empty"
        return 1
    fi

    if [[ -f .env ]]; then
        # shellcheck disable=SC1091
        source .env
    fi

    # Not fatal: offline work (rendering, validation) needs no credentials.
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
    export RUNTIME_ENGINE RUNTIME_GPU INSTANCES_DIR ROUTER_MAP CONFIG_FILE
}

# Per-instance value, falling back to defaults.
# Uses has() rather than `//` — yq's alternative operator treats `false` and ""
# as absent, so `false // default` would silently return the default.
_ivalue() {
    local name="$1" key="$2"
    if [[ "$(yq -r ".instances.\"$name\" | has(\"$key\")" "$CONFIG_FILE")" == "true" ]]; then
        yq -r ".instances.\"$name\".$key" "$CONFIG_FILE"
    elif [[ "$(yq -r ".defaults | has(\"$key\")" "$CONFIG_FILE")" == "true" ]]; then
        yq -r ".defaults.$key" "$CONFIG_FILE"
    else
        printf 'null'
    fi
}

# Populate INST_* for one instance and derive its context total.
load_instance() {
    local name="$1"
    INST_NAME="$name"
    INST_PORT=$(_ivalue "$name" port)
    INST_MODEL_FILE=$(_ivalue "$name" model_file)
    INST_CONTEXT_PER_REQUEST=$(_ivalue "$name" context_per_request)
    INST_PARALLEL_SLOTS=$(_ivalue "$name" parallel_slots)
    INST_KV_UNIFIED=$(_ivalue "$name" kv_unified)
    INST_BATCH_SIZE=$(_ivalue "$name" batch_size)
    INST_UBATCH_SIZE=$(_ivalue "$name" ubatch_size)
    INST_THREADS_GEN=$(_ivalue "$name" threads_gen)
    INST_THREADS_BATCH=$(_ivalue "$name" threads_batch)
    INST_THREADS_HTTP=$(_ivalue "$name" threads_http)
    INST_CACHE_REUSE=$(_ivalue "$name" cache_reuse)
    INST_CACHE_TYPE_K=$(_ivalue "$name" cache_type_k)
    INST_CACHE_TYPE_V=$(_ivalue "$name" cache_type_v)
    INST_FLASH_ATTN=$(_ivalue "$name" flash_attn)
    INST_DRAFT_MAX=$(_ivalue "$name" draft_max)
    INST_CONTAINER_IMAGE=$(_ivalue "$name" container_image)

    INST_DRAFT_MODEL=$(_ivalue "$name" draft_model)
    [[ "$INST_DRAFT_MODEL" == "null" ]] && INST_DRAFT_MODEL=""

    local p="instances.$name"
    _require_int "$p.port" "$INST_PORT" || return 1
    _require_int "$p.context_per_request" "$INST_CONTEXT_PER_REQUEST" || return 1
    _require_int "$p.parallel_slots" "$INST_PARALLEL_SLOTS" || return 1
    _require_int "$p.batch_size" "$INST_BATCH_SIZE" || return 1
    _require_int "$p.ubatch_size" "$INST_UBATCH_SIZE" || return 1
    _require_int "$p.threads_gen" "$INST_THREADS_GEN" || return 1
    _require_int "$p.threads_batch" "$INST_THREADS_BATCH" || return 1
    _require_int "$p.threads_http" "$INST_THREADS_HTTP" || return 1
    _require_int "$p.cache_reuse" "$INST_CACHE_REUSE" || return 1
    _require_int "$p.draft_max" "$INST_DRAFT_MAX" || return 1
    _require_enum "$p.kv_unified" "$INST_KV_UNIFIED" true false || return 1
    _require_enum "$p.flash_attn" "$INST_FLASH_ATTN" true false || return 1

    if [[ -z "$INST_MODEL_FILE" || "$INST_MODEL_FILE" == "null" ]]; then
        _cfg_err "$p.model_file is not set"
        return 1
    fi
    if ((INST_UBATCH_SIZE > INST_BATCH_SIZE)); then
        _cfg_err "$p: ubatch_size ($INST_UBATCH_SIZE) must not exceed batch_size ($INST_BATCH_SIZE)"
        return 1
    fi
    # Asymmetric K/V types silently fall back to CPU attention: 25-45x slower.
    if [[ "$INST_CACHE_TYPE_K" != "$INST_CACHE_TYPE_V" ]]; then
        _cfg_err "$p: cache_type_k ($INST_CACHE_TYPE_K) must equal cache_type_v ($INST_CACHE_TYPE_V)"
        return 1
    fi

    # A quantized V cache requires flash attention, so llama.cpp force-enables
    # it and flash_attn:false silently has no effect. Warn rather than block:
    # this combination is in production and works, it just doesn't mean what
    # it says.
    # load_instance is called repeatedly; only warn once per instance.
    if [[ -z "${_WARNED[$name]:-}" ]]; then
        _WARNED[$name]=1
        case "$INST_CACHE_TYPE_V" in
            f16|f32|bf16) ;;
            *)
                if [[ "$INST_FLASH_ATTN" == "false" ]]; then
                    echo -e "${YELLOW}Warning:${NC} $p has flash_attn: false with a quantized cache_type_v ($INST_CACHE_TYPE_V)." >&2
                    echo "  llama.cpp force-enables flash attention for a quantized V cache," >&2
                    echo "  so flash_attn: false has no effect. Use f16 to actually disable it." >&2
                fi
                ;;
        esac
        # Quantizing the target model's KV cache can collapse draft acceptance.
        if [[ -n "$INST_DRAFT_MODEL" && "$INST_CACHE_TYPE_K" != "f16" ]]; then
            echo -e "${YELLOW}Warning:${NC} $p uses a draft model with a quantized KV cache ($INST_CACHE_TYPE_K)," >&2
            echo "  which can collapse draft acceptance. Consider f16 while speculative decoding." >&2
        fi
    fi

    # llama.cpp: n_ctx_seq = kv_unified ? n_ctx : PAD256(n_ctx / n_seq_max)
    if [[ "$INST_KV_UNIFIED" == "true" ]]; then
        INST_TOTAL_CONTEXT="$INST_CONTEXT_PER_REQUEST"
    else
        INST_TOTAL_CONTEXT=$((INST_CONTEXT_PER_REQUEST * INST_PARALLEL_SLOTS))
    fi
}

# Effective per-request window llama.cpp will actually produce, including its
# 256-token padding. Used to prove the derivation round-trips.
effective_ctx_per_request() {
    local total="$1" slots="$2" unified="$3"
    if [[ "$unified" == "true" ]]; then
        printf '%s' "$total"
        return
    fi
    local per=$((total / slots))
    printf '%s' $(((per + 255) / 256 * 256))
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

test_ssh() {
    case "$SSH_AUTH" in
        local) return 0 ;;
        none)  _no_auth; return 1 ;;
        *)     _ssh_run -o ConnectTimeout=5 "$REMOTE_USER@$REMOTE_HOST" true 2>/dev/null ;;
    esac
}

remote_exec() {
    case "$SSH_AUTH" in
        local) bash -c "$*"; return ;;
        none)  _no_auth; return 1 ;;
        *)     _ssh_run "$REMOTE_USER@$REMOTE_HOST" "$*" ;;
    esac
}

# Single-quote a string for safe interpolation into a remote shell
_shq() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

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
        _ssh_run "$REMOTE_USER@$REMOTE_HOST" "printf '%s\n' $(_shq "$SSH_PASS") | sudo -S bash -c $(_shq "$*")"
    else
        _ssh_run "$REMOTE_USER@$REMOTE_HOST" "sudo bash -c $(_shq "$*")"
    fi
}

# Write stdin to a privileged path on the target.
# remote_exec_sudo consumes stdin to feed `sudo -S` the password, so content
# must never be piped through it — it arrives empty. Stage via a temp file.
remote_write_sudo() {
    local dest="$1" mode="${2:-644}" tmp owner
    tmp="/tmp/.llama-deploy.$$.${RANDOM}"

    remote_exec "cat > $tmp" || return 1
    owner=$(remote_exec "stat -c '%U:%G' $dest 2>/dev/null" || echo "")
    if [[ -n "$owner" ]]; then
        remote_exec_sudo "install -m $mode -o ${owner%%:*} -g ${owner##*:} $tmp $dest && rm -f $tmp"
    else
        remote_exec_sudo "install -m $mode $tmp $dest && rm -f $tmp"
    fi
}

# Read a key from an instance conf on the target.
# `grep | cut || echo default` can never work: the pipeline exits with cut's
# status, which is always 0. Check for emptiness explicitly instead.
remote_conf_value() {
    local file="$1" key="$2" default="${3:-}" value=""
    value=$(remote_exec "grep '^$key=' $file 2>/dev/null | cut -d= -f2-" 2>/dev/null) || value=""
    value="${value%$'\r'}"
    if [[ -z "$value" ]]; then
        printf '%s' "$default"
    else
        printf '%s' "$value"
    fi
}

print_config() {
    echo -e "${YELLOW}Target:${NC} $REMOTE_USER@$REMOTE_HOST ($RUNTIME_ENGINE/$RUNTIME_GPU)"
    echo -e "${YELLOW}Instances:${NC} ${#INSTANCE_NAMES[@]} in $INSTANCES_DIR"
    local n
    for n in "${INSTANCE_NAMES[@]}"; do
        load_instance "$n" || continue
        printf '  %-14s :%s  %6s/req x %-3s slots = -c %-8s  KV %-5s fa=%s\n' \
            "$n" "$INST_PORT" "$INST_CONTEXT_PER_REQUEST" "$INST_PARALLEL_SLOTS" \
            "$INST_TOTAL_CONTEXT" "$INST_CACHE_TYPE_K" "$INST_FLASH_ATTN"
    done
}
