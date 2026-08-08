#!/bin/bash
# Offline tests: config validation, derived context arithmetic, and golden
# renders of /etc/llama-server.conf and the systemd unit.
#
# No network, no SSH, no server. Safe to run anywhere.
#
# Usage: ./tests/test-render.sh [test-name]
#        ./tests/test-render.sh --accept    regenerate golden files
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

GOLDEN="tests/golden"
FIXTURES="tests/fixtures"
DEPLOY="./scripts/deploy-llama.sh"

# Fixed base values so renders don't depend on a live server
export BASE_LLAMA_PORT=8080
export BASE_LLAMA_HOST=0.0.0.0
export BASE_MODEL_FILE=Qwen3-14B-Q4_K_M.gguf
export BASE_CONTAINER_IMAGE=example.invalid/llama:test
export BASE_LLAMA_API_KEY=TESTKEY

PASSED=0
FAILED=0
pass() { echo -e "${GREEN}PASS${NC}: $*"; PASSED=$((PASSED + 1)); }
fail() { echo -e "${RED}FAIL${NC}: $*"; FAILED=$((FAILED + 1)); }

render() { LLAMA_CONFIG="$FIXTURES/$1.yaml" "$DEPLOY" "--render-$2" 2>&1; }

# Build a config on the fly from the amd fixture with one key overridden
mutate() {
    local key="$1" value="$2" out="$3"
    yq "$key = $value" "$FIXTURES/amd.yaml" > "$out"
}

# ── Golden renders ────────────────────────────────────────────────────────────
check_golden() {
    local name="$1" kind="$2"
    local expected="$GOLDEN/$name.$kind"
    local actual
    actual=$(mktemp)
    render "$name" "$kind" > "$actual"

    if [[ ! -f "$expected" ]]; then
        fail "$name $kind: no golden file at $expected (run --accept)"
        rm -f "$actual"
        return
    fi
    if diff -u "$expected" "$actual"; then
        pass "$name $kind matches golden"
    else
        fail "$name $kind differs from golden (run --accept if intended)"
    fi
    rm -f "$actual"
}

test_golden_amd_conf()   { echo "TEST: amd conf render";   check_golden amd conf; }
test_golden_amd_unit()   { echo "TEST: amd unit render";   check_golden amd unit; }
test_golden_nvidia_conf(){ echo "TEST: nvidia conf render"; check_golden nvidia conf; }
test_golden_nvidia_unit(){ echo "TEST: nvidia unit render"; check_golden nvidia unit; }

# ── The arithmetic this whole change is about ─────────────────────────────────
test_context_is_multiplied_not_divided() {
    echo "TEST: -c is derived as context_per_request x parallel_slots"
    local conf
    conf=$(render amd conf)

    local per total slots
    per=$(grep -oP '^CONTEXT_PER_REQUEST=\K.*' <<<"$conf")
    total=$(grep -oP '^CONTEXT_SIZE=\K.*' <<<"$conf")
    slots=$(grep -oP '^PARALLEL_SLOTS=\K.*' <<<"$conf")

    if [[ "$total" != "$((per * slots))" ]]; then
        fail "CONTEXT_SIZE=$total != $per x $slots"
        return
    fi
    pass "CONTEXT_SIZE=$total = $per per request x $slots slots"
}

test_kv_unified_uses_context_directly() {
    echo "TEST: kv_unified:true sets -c to context_per_request, undivided"
    local cfg conf total per
    cfg=$(mktemp --suffix=.yaml)
    mutate '.llama.kv_unified' 'true' "$cfg"

    conf=$(LLAMA_CONFIG="$cfg" "$DEPLOY" --render-conf 2>&1)
    per=$(grep -oP '^CONTEXT_PER_REQUEST=\K.*' <<<"$conf")
    total=$(grep -oP '^CONTEXT_SIZE=\K.*' <<<"$conf")
    rm -f "$cfg"

    if [[ "$total" != "$per" ]]; then
        fail "kv_unified:true should give CONTEXT_SIZE == CONTEXT_PER_REQUEST, got $total vs $per"
        return
    fi
    pass "kv_unified:true -> -c $total (shared pool)"
}

test_unit_emits_kv_unified_flag() {
    echo "TEST: unit passes an explicit --no-kv-unified / --kv-unified"
    local unit
    unit=$(render amd unit)
    if ! grep -q -- '--no-kv-unified' <<<"$unit"; then
        fail "kv_unified:false did not emit --no-kv-unified"
        return
    fi
    # An explicit -np turns the unified default OFF, so relying on the default
    # is what silently divided the context in the first place.
    pass "unit emits --no-kv-unified explicitly"
}

test_per_request_meets_floor() {
    echo "TEST: config/llama.yaml delivers >= 8192 tokens per request"
    local conf per
    conf=$(LLAMA_CONFIG=config/llama.yaml "$DEPLOY" --render-conf 2>&1) || {
        fail "could not render config/llama.yaml"
        return
    }
    per=$(grep -oP '^CONTEXT_PER_REQUEST=\K.*' <<<"$conf")
    if [[ ! "$per" =~ ^[0-9]+$ ]] || ((per < 8192)); then
        fail "context_per_request=$per is below the 8192 floor from CONTEXT_SIZE_ISSUE.md"
        return
    fi
    pass "context_per_request=$per meets the 8192 floor"
}

# ── Platform ──────────────────────────────────────────────────────────────────
test_amd_and_nvidia_units_differ() {
    echo "TEST: AMD and NVIDIA units use the right runtime and GPU flags"
    local amd nvidia
    amd=$(render amd unit)
    nvidia=$(render nvidia unit)

    grep -q '/usr/bin/podman' <<<"$amd"     || { fail "amd unit missing podman"; return; }
    grep -q -- '--device /dev/kfd' <<<"$amd" || { fail "amd unit missing /dev/kfd"; return; }
    grep -q -- '--gpus all' <<<"$amd"       && { fail "amd unit must not use --gpus all"; return; }

    grep -q '/usr/bin/docker' <<<"$nvidia"  || { fail "nvidia unit missing docker"; return; }
    grep -q -- '--gpus all' <<<"$nvidia"    || { fail "nvidia unit missing --gpus all"; return; }
    grep -q -- '--device /dev/kfd' <<<"$nvidia" && { fail "nvidia unit must not use /dev/kfd"; return; }
    grep -q 'Requires=docker.service' <<<"$nvidia" || { fail "nvidia unit missing docker.service dep"; return; }

    pass "AMD uses podman+kfd, NVIDIA uses docker+gpus"
}

test_entrypoint_arg_is_engine_specific() {
    echo "TEST: 'llama-server' argv element only on the podman/AMD image"
    local amd nvidia
    amd=$(render amd unit)
    nvidia=$(render nvidia unit)

    # The AMD toolbox image entrypoint is a shell, so the binary must be named.
    if ! grep -qE '^\s+llama-server \\$' <<<"$amd"; then
        fail "amd unit is missing the 'llama-server' argv element"
        return
    fi
    # The ggml CUDA image entrypoint IS llama-server; naming it corrupts argv.
    if grep -qE '^\s+llama-server \\$' <<<"$nvidia"; then
        fail "nvidia unit must not name 'llama-server' — the image entrypoint already is"
        return
    fi
    pass "podman unit names llama-server, docker unit does not"
}

test_flash_attn_flag() {
    echo "TEST: -fa on appears only when flash_attn is true"
    local off on
    off=$(render amd unit)      # flash_attn: false
    on=$(render nvidia unit)    # flash_attn: true

    if grep -q -- '-fa on' <<<"$off"; then
        fail "flash_attn:false still emitted -fa on"
        return
    fi
    if ! grep -q -- '-fa on' <<<"$on"; then
        fail "flash_attn:true did not emit -fa on"
        return
    fi
    pass "flash_attn drives the -fa flag"
}

test_draft_model_flags() {
    echo "TEST: speculative decoding flags appear only with a draft model"
    local none with cfg
    none=$(render amd unit)
    if grep -q -- '-md ' <<<"$none"; then
        fail "empty draft_model still emitted -md"
        return
    fi

    cfg=$(mktemp --suffix=.yaml)
    mutate '.llama.draft_model' '"Qwen3-1.5B-Q4_K_M.gguf"' "$cfg"
    with=$(LLAMA_CONFIG="$cfg" "$DEPLOY" --render-unit 2>&1)
    rm -f "$cfg"

    local f
    for f in '-md /models/Qwen3-1.5B-Q4_K_M.gguf' '--draft-max 16' '-ngld 999'; do
        if ! grep -q -- "$f" <<<"$with"; then
            fail "draft model set but '$f' missing"
            return
        fi
    done
    pass "draft_model drives -md/--draft-max/-ngld"
}

test_rejects_quantized_kv_without_flash_attn() {
    echo "TEST: quantized V cache without flash attention is rejected"
    local cfg out rc
    cfg=$(mktemp --suffix=.yaml)
    # amd fixture is flash_attn:false; make the cache quantized
    yq '.llama.cache_type_k = "q8_0" | .llama.cache_type_v = "q8_0"' \
        "$FIXTURES/amd.yaml" > "$cfg"
    out=$(LLAMA_CONFIG="$cfg" "$DEPLOY" --render-conf 2>&1)
    rc=$?
    rm -f "$cfg"

    if ((rc == 0)); then
        fail "q8_0 KV with flash_attn:false was accepted"
        echo "  llama.cpp force-enables FA here, silently defeating flash_attn:false"
        return
    fi
    if ! grep -qi 'flash' <<<"$out"; then
        fail "rejection message does not explain the flash attention requirement"
        return
    fi
    pass "quantized V + flash_attn:false rejected"
}

test_units_are_valid_systemd() {
    echo "TEST: rendered units pass systemd-analyze verify"
    if ! command -v systemd-analyze >/dev/null 2>&1; then
        echo "SKIP: systemd-analyze not available"
        return
    fi
    local name dir problems
    for name in amd nvidia; do
        dir=$(mktemp -d)
        render "$name" unit > "$dir/llama-server.service"
        # "not executable" is expected: the target's binaries aren't on this host.
        problems=$(systemd-analyze verify "$dir/llama-server.service" 2>&1 \
            | grep -v 'is not executable' | grep -v '^$' || true)
        rm -rf "$dir"
        if [[ -n "$problems" ]]; then
            fail "$name unit invalid: $problems"
            return
        fi
    done
    pass "both units are structurally valid"
}

# ── Config validation ─────────────────────────────────────────────────────────
expect_reject() {
    local label="$1" key="$2" value="$3" cfg out
    cfg=$(mktemp --suffix=.yaml)
    mutate "$key" "$value" "$cfg"
    out=$(LLAMA_CONFIG="$cfg" "$DEPLOY" --render-conf 2>&1)
    local rc=$?
    rm -f "$cfg"
    if ((rc == 0)); then
        fail "$label was accepted but should be rejected"
    else
        pass "$label rejected: $(head -1 <<<"$out" | sed 's/\x1b\[[0-9;]*m//g')"
    fi
}

test_rejects_bad_config() {
    echo "TEST: invalid configs are rejected, not silently deployed"
    expect_reject "ubatch_size > batch_size" '.llama.ubatch_size' '4096'
    expect_reject "asymmetric cache types"   '.llama.cache_type_v' '"q8_0"'
    expect_reject "zero parallel_slots"      '.llama.parallel_slots' '0'
    expect_reject "unknown runtime engine"   '.runtime.engine' '"containerd"'
}

test_rejects_missing_context_key() {
    echo "TEST: a missing context_per_request is rejected, not passed as 'null'"
    local cfg out rc
    cfg=$(mktemp --suffix=.yaml)
    yq 'del(.llama.context_per_request)' "$FIXTURES/amd.yaml" > "$cfg"
    out=$(LLAMA_CONFIG="$cfg" "$DEPLOY" --render-conf 2>&1)
    rc=$?
    rm -f "$cfg"

    if ((rc == 0)); then
        fail "missing context_per_request rendered anyway"
        grep -i 'CONTEXT' <<<"$out" | head -3
        return
    fi
    pass "missing context_per_request rejected"
}

test_rejects_legacy_context_size() {
    echo "TEST: the old context_size key fails with a migration message"
    local cfg out rc
    cfg=$(mktemp --suffix=.yaml)
    yq 'del(.llama.context_per_request) | .llama.context_size = 32768' \
        "$FIXTURES/amd.yaml" > "$cfg"
    out=$(LLAMA_CONFIG="$cfg" "$DEPLOY" --render-conf 2>&1)
    rc=$?
    rm -f "$cfg"

    if ((rc == 0)); then
        fail "legacy context_size was silently accepted"
        return
    fi
    if ! grep -q 'context_per_request' <<<"$out"; then
        fail "rejection message does not mention the replacement key"
        return
    fi
    pass "legacy context_size rejected with migration hint"
}

# ── Runner ────────────────────────────────────────────────────────────────────
accept_goldens() {
    mkdir -p "$GOLDEN"
    local name kind
    for name in amd nvidia; do
        for kind in conf unit; do
            render "$name" "$kind" > "$GOLDEN/$name.$kind"
            echo "wrote $GOLDEN/$name.$kind"
        done
    done
}

if [[ "${1:-}" == "--accept" ]]; then
    accept_goldens
    exit 0
fi

echo -e "${BLUE}Offline render + config tests${NC}\n"

if [[ $# -ge 1 ]]; then
    "$1"
else
    for t in test_golden_amd_conf test_golden_amd_unit \
             test_golden_nvidia_conf test_golden_nvidia_unit \
             test_context_is_multiplied_not_divided \
             test_kv_unified_uses_context_directly \
             test_unit_emits_kv_unified_flag \
             test_per_request_meets_floor \
             test_amd_and_nvidia_units_differ \
             test_entrypoint_arg_is_engine_specific \
             test_flash_attn_flag \
             test_draft_model_flags \
             test_rejects_quantized_kv_without_flash_attn \
             test_units_are_valid_systemd \
             test_rejects_bad_config \
             test_rejects_missing_context_key \
             test_rejects_legacy_context_size; do
        "$t"
        echo ""
    done
fi

echo "─────────────────────────────────────────"
echo -e "${GREEN}$PASSED passed${NC}, ${RED}$FAILED failed${NC}"
[[ "$FAILED" -eq 0 ]]
