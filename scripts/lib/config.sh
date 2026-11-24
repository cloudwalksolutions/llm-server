#!/usr/bin/env bash

# KV cache types llama.cpp accepts for -ctk/-ctv. A typo here renders and
# deploys cleanly, then the container refuses to start and the deploy burns its
# full health-check timeout before rolling back.
_KV_CACHE_TYPES="f32 f16 bf16 q8_0 q4_0 q4_1 q5_0 q5_1 iq4_nl"

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

    RUNTIME_ENGINE=$(yq '.runtime.engine' "$CONFIG_FILE")
    RUNTIME_GPU=$(yq '.runtime.gpu' "$CONFIG_FILE")
    INSTANCES_DIR=$(yq '.runtime.instances_dir // "/opt/llm/instances"' "$CONFIG_FILE")
    ROUTER_MAP=$(yq '.runtime.router_map // "/etc/llama-router/models.json"' "$CONFIG_FILE")
    MODELS_DIR=$(yq '.runtime.models_dir // "/opt/llm/models"' "$CONFIG_FILE")
    FFMPEG_DIR=/opt/llm/ffmpeg
    UNIT_PATH=$(yq '.runtime.unit_path // "/etc/systemd/system/llama-server@.service"' "$CONFIG_FILE")
    ROUTER_CONF=$(yq '.runtime.router_conf // "/etc/nginx/conf.d/llama-router.conf"' "$CONFIG_FILE")
    ROUTER_JS=$(yq '.runtime.router_js // "/etc/nginx/njs/llama-router.js"' "$CONFIG_FILE")
    ROUTER_DEFAULT=$(yq '.runtime.router_default // ""' "$CONFIG_FILE")

    _require_enum "runtime.engine" "$RUNTIME_ENGINE" podman docker || return 1
    _require_enum "runtime.gpu" "$RUNTIME_GPU" amd nvidia || return 1
    GTT_FREE_FLOOR_GIB=$(yq '.runtime.gtt_free_floor_gib // 0' "$CONFIG_FILE")
    MEM_AVAILABLE_FLOOR_GIB=$(yq '.runtime.mem_available_floor_gib // 0' "$CONFIG_FILE")
    _require_uint "runtime.gtt_free_floor_gib" "$GTT_FREE_FLOOR_GIB" || return 1
    _require_uint "runtime.mem_available_floor_gib" "$MEM_AVAILABLE_FLOOR_GIB" || return 1

    # Rendered into the unit template. These were dead config until deploy took
    # ownership of the unit — the values were hardcoded on the target.
    RES_LIMIT_NOFILE=$(yq '.resources.limit_nofile // 65535' "$CONFIG_FILE")
    RES_LIMIT_MEMLOCK=$(yq '.resources.limit_memlock // "infinity"' "$CONFIG_FILE")
    _require_int "resources.limit_nofile" "$RES_LIMIT_NOFILE" || return 1
    _require_no_control_chars "resources.limit_memlock" "$RES_LIMIT_MEMLOCK" || return 1

    if [[ "$(yq '.remote' "$CONFIG_FILE")" != "null" ]]; then
        _cfg_err "remote: belongs in .env, not in $CONFIG_FILE"
        echo "  Set LLM_SSH_HOST, LLM_SSH_USER and optionally LLM_SSH_JUMP there; this repo is public." >&2
        return 1
    fi

    # The old schema was a single flat llama: block. Refuse to guess.
    if [[ "$(yq '.instances' "$CONFIG_FILE")" == "null" ]]; then
        _cfg_err "no 'instances:' block found"
        echo "  This target runs one llama-server per model via llama-server@<name>.service." >&2
        echo "  See config/llama.example.yaml for the schema." >&2
        return 1
    fi

    FFMPEG_URL=$(yq '.runtime.ffmpeg.url' "$CONFIG_FILE")
    _require_match "runtime.ffmpeg.url" "$FFMPEG_URL" '^https://[^[:space:]]+$' || return 1
    FFMPEG_SHA256=$(yq '.runtime.ffmpeg.sha256' "$CONFIG_FILE")
    _require_match "runtime.ffmpeg.sha256" "$FFMPEG_SHA256" '^[0-9a-f]{64}$' || return 1

    mapfile -t INSTANCE_NAMES < <(yq -r '.instances | to_entries | .[] | select(.value.enabled != false) | .key' "$CONFIG_FILE")
    if ((${#INSTANCE_NAMES[@]} == 0)); then
        _cfg_err "'instances:' is empty"
        return 1
    fi

    # The name is a systemd instance suffix, an nginx routing key, a filename,
    # and an interpolation into both a yq expression and a remote `sudo bash -c`.
    # Anything outside this set breaks at least one of those, and a quote breaks
    # it as a wall of yq lexer errors rather than a config error.
    local n
    for n in "${INSTANCE_NAMES[@]}"; do
        if [[ ! "$n" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
            _cfg_err "instance name '$n' must match [A-Za-z0-9][A-Za-z0-9_.-]*"
            echo "  The name is used as a systemd unit suffix, a filename, and the routing key." >&2
            return 1
        fi
    done

    # Two instances on one port: whichever binds first wins and the other
    # crash-loops. The router-map check only compares each name to its own port,
    # so nothing else catches this.
    local -A _seen_ports=()
    local p
    for n in "${INSTANCE_NAMES[@]}"; do
        p=$(_ivalue "$n" port)
        [[ "$p" == "null" || -z "$p" ]] && continue
        if [[ -n "${_seen_ports[$p]:-}" ]]; then
            _cfg_err "instances '${_seen_ports[$p]}' and '$n' both use port $p"
            return 1
        fi
        _seen_ports[$p]="$n"
    done

    load_comfyui || return 1
    load_target

    export RUNTIME_ENGINE RUNTIME_GPU INSTANCES_DIR ROUTER_MAP CONFIG_FILE
    export MODELS_DIR UNIT_PATH RES_LIMIT_NOFILE RES_LIMIT_MEMLOCK
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
    INST_SPEC_TYPE=$(_ivalue "$name" spec_type)
    INST_REASONING=$(_ivalue "$name" reasoning)
    INST_REASONING_BUDGET=$(_ivalue "$name" reasoning_budget)
    INST_CACHE_RAM=$(_ivalue "$name" cache_ram)
    INST_REASONING_BUDGET_MESSAGE=$(_ivalue "$name" reasoning_budget_message)
    INST_CONTAINER_IMAGE=$(_ivalue "$name" container_image)
    INST_SAMPLING=$(yq -o=json -I=0 ".instances.\"$name\".sampling // {}" "$CONFIG_FILE")

    INST_DRAFT_MODEL=$(_ivalue "$name" draft_model)
    [[ "$INST_DRAFT_MODEL" == "null" ]] && INST_DRAFT_MODEL=""
    INST_MMPROJ_FILE=$(_ivalue "$name" mmproj_file)
    [[ "$INST_MMPROJ_FILE" == "null" ]] && INST_MMPROJ_FILE=""
    INST_IMAGE_MIN_TOKENS=$(_ivalue "$name" image_min_tokens)
    [[ "$INST_IMAGE_MIN_TOKENS" == "null" ]] && INST_IMAGE_MIN_TOKENS=0

    local p="instances.$name"
    _require_int "$p.port" "$INST_PORT" || return 1
    _require_int "$p.context_per_request" "$INST_CONTEXT_PER_REQUEST" || return 1
    _require_int "$p.parallel_slots" "$INST_PARALLEL_SLOTS" || return 1
    _require_int "$p.batch_size" "$INST_BATCH_SIZE" || return 1
    _require_int "$p.ubatch_size" "$INST_UBATCH_SIZE" || return 1
    _require_int "$p.threads_gen" "$INST_THREADS_GEN" || return 1
    _require_int "$p.threads_batch" "$INST_THREADS_BATCH" || return 1
    _require_int "$p.threads_http" "$INST_THREADS_HTTP" || return 1
    _require_uint "$p.cache_reuse" "$INST_CACHE_REUSE" || return 1
    _require_uint "$p.draft_max" "$INST_DRAFT_MAX" || return 1
    _require_uint "$p.reasoning_budget" "$INST_REASONING_BUDGET" || return 1
    _require_uint "$p.cache_ram" "$INST_CACHE_RAM" || return 1
    _require_enum "$p.kv_unified" "$INST_KV_UNIFIED" true false || return 1
    _require_enum "$p.flash_attn" "$INST_FLASH_ATTN" true false || return 1
    _require_enum "$p.spec_type" "$INST_SPEC_TYPE" draft-simple draft-mtp || return 1
    _require_enum "$p.reasoning" "$INST_REASONING" on off auto || return 1
    # shellcheck disable=SC2086
    _require_enum "$p.cache_type_k" "$INST_CACHE_TYPE_K" $_KV_CACHE_TYPES || return 1
    # shellcheck disable=SC2086
    _require_enum "$p.cache_type_v" "$INST_CACHE_TYPE_V" $_KV_CACHE_TYPES || return 1

    _require_str "$p.model_file" "$INST_MODEL_FILE" || return 1
    _require_str "$p.container_image" "$INST_CONTAINER_IMAGE" || return 1

    _require_no_control_chars "$p.model_file"      "$INST_MODEL_FILE"      || return 1
    _require_no_control_chars "$p.container_image" "$INST_CONTAINER_IMAGE" || return 1
    _require_no_control_chars "$p.draft_model"     "$INST_DRAFT_MODEL"     || return 1
    _require_no_control_chars "$p.mmproj_file"     "$INST_MMPROJ_FILE"     || return 1
    _require_uint "$p.image_min_tokens" "$INST_IMAGE_MIN_TOKENS" || return 1
    _require_str "$p.reasoning_budget_message" "$INST_REASONING_BUDGET_MESSAGE" || return 1
    _require_no_control_chars "$p.reasoning_budget_message" "$INST_REASONING_BUDGET_MESSAGE" || return 1
    if [[ "$INST_REASONING_BUDGET_MESSAGE" == *[\"\\\$\`]* ]]; then
        _cfg_err "$p.reasoning_budget_message may not contain \", \\, \$ or a backtick"
        return 1
    fi
    local flags='{"temperature":"--temp","top_p":"--top-p","top_k":"--top-k","min_p":"--min-p","presence_penalty":"--presence-penalty"}'
    if ! jq -e --argjson f "$flags" 'to_entries | all(($f[.key] != null) and (.value | type == "number"))' <<<"$INST_SAMPLING" >/dev/null; then
        _cfg_err "$p.sampling takes numbers for: $(jq -r 'keys | join(", ")' <<<"$flags")"
        return 1
    fi
    INST_SAMPLING_ARGS=$(jq -r --argjson f "$flags" 'to_entries | map("\($f[.key]) \(.value)") | join(" ")' <<<"$INST_SAMPLING")
    if ((INST_UBATCH_SIZE > INST_BATCH_SIZE)); then
        _cfg_err "$p: ubatch_size ($INST_UBATCH_SIZE) must not exceed batch_size ($INST_BATCH_SIZE)"
        return 1
    fi
    # Asymmetric K/V types silently fall back to CPU attention: 25-45x slower.
    if [[ "$INST_CACHE_TYPE_K" != "$INST_CACHE_TYPE_V" ]]; then
        _cfg_err "$p: cache_type_k ($INST_CACHE_TYPE_K) must equal cache_type_v ($INST_CACHE_TYPE_V)"
        return 1
    fi

    # flash_attn: false does not disable flash attention — it only omits -fa,
    # which leaves llama.cpp on its own default of `auto`. Measured on the
    # target (journal, 2026-08-08):
    #   llama_context: flash_attn = auto
    #   sched_reserve: Flash Attention was auto, set to enabled
    # So FA is ON for every instance here, and a quantized V cache needs it —
    # llama.cpp refuses to start with `V cache quantization requires flash_attn`
    # if it resolves to off. Warn rather than block: this is production and it
    # works, the setting just doesn't mean what its name suggests.
    # load_instance is called repeatedly; only warn once per instance.
    if [[ -z "${_WARNED[$name]:-}" ]]; then
        _WARNED[$name]=1
        case "$INST_CACHE_TYPE_V" in
            f16|f32|bf16) ;;
            *)
                if [[ "$INST_FLASH_ATTN" == "false" ]]; then
                    echo -e "${YELLOW}Warning:${NC} $p has flash_attn: false with a quantized cache_type_v ($INST_CACHE_TYPE_V)." >&2
                    echo "  This does not disable flash attention. false only omits -fa, so llama.cpp" >&2
                    echo "  falls back to its own default of 'auto' and resolves it to enabled — which" >&2
                    echo "  a quantized V cache requires anyway." >&2
                    echo "  Read the resolved state from 'make status' (flash-at), not from this setting." >&2
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
        INST_KV_POOL=$(_ivalue "$name" kv_pool)
        _require_int "$p.kv_pool" "$INST_KV_POOL" || return 1
        if ((INST_KV_POOL < INST_CONTEXT_PER_REQUEST)); then
            _cfg_err "$p.kv_pool ($INST_KV_POOL) is smaller than one request's context_per_request ($INST_CONTEXT_PER_REQUEST)"
            return 1
        fi
        INST_TOTAL_CONTEXT="$INST_KV_POOL"
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
