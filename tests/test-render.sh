#!/bin/bash
# Offline tests: config validation, defaults/override merging, derived context
# arithmetic, and golden renders of the per-instance conf files.
#
# No network, no SSH, no server. Safe to run anywhere.
#
# Usage: ./tests/test-render.sh [test-name]
#        ./tests/test-render.sh --accept    regenerate golden files
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
# shellcheck source=scripts/lib/common.sh
source scripts/lib/common.sh

GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

GOLDEN="tests/golden"
FIXTURES="tests/fixtures"
DEPLOY="./scripts/deploy-llama.sh"
export BASE_LLAMA_API_KEY=TESTKEY

PASSED=0
FAILED=0
pass() { echo -e "${GREEN}PASS${NC}: $*"; PASSED=$((PASSED + 1)); }
fail() { echo -e "${RED}FAIL${NC}: $*"; FAILED=$((FAILED + 1)); }

render() { LLAMA_CONFIG="$FIXTURES/$1.yaml" "$DEPLOY" --render "$2" 2>&1; }

# Load a fixture into the current shell so INST_* can be inspected directly
use_fixture() { load_config "$FIXTURES/$1.yaml" >/dev/null 2>&1; }

conf_val() { grep -oP "^$2=\K.*" <<<"$1"; }

# ── Golden renders ────────────────────────────────────────────────────────────
check_golden() {
    local fixture="$1" inst="$2"
    local expected="$GOLDEN/$fixture.$inst.conf"
    local actual
    actual=$(mktemp)
    render "$fixture" "$inst" > "$actual"

    if [[ ! -f "$expected" ]]; then
        fail "$fixture/$inst: no golden at $expected (run --accept)"
        rm -f "$actual"; return
    fi
    if diff -u "$expected" "$actual"; then
        pass "$fixture/$inst matches golden"
    else
        fail "$fixture/$inst differs from golden (run --accept if intended)"
    fi
    rm -f "$actual"
}

test_golden_renders() {
    echo "TEST: instance confs match goldens"
    check_golden amd base
    check_golden amd overridden
    check_golden nvidia shared
}

# ── The arithmetic this whole change is about ─────────────────────────────────
test_context_is_multiplied_not_divided() {
    echo "TEST: CONTEXT_SIZE = context_per_request x parallel_slots"
    local out total slots
    out=$(render amd base)
    total=$(conf_val "$out" CONTEXT_SIZE)
    slots=$(conf_val "$out" PARALLEL_SLOTS)
    if [[ "$total" != "$((16384 * slots))" ]]; then
        fail "CONTEXT_SIZE=$total, expected $((16384 * slots))"
        return
    fi
    pass "CONTEXT_SIZE=$total = 16384 x $slots"
}

test_kv_unified_is_not_divided() {
    echo "TEST: kv_unified:true leaves CONTEXT_SIZE undivided"
    local out total
    out=$(render nvidia shared)
    total=$(conf_val "$out" CONTEXT_SIZE)
    if [[ "$total" != "8192" ]]; then
        fail "kv_unified:true should give CONTEXT_SIZE=8192, got $total"
        return
    fi
    pass "kv_unified:true -> -c 8192 for 2 slots"
}

# The number must survive llama.cpp's PAD256 rounding, or the config lies.
test_derivation_round_trips() {
    echo "TEST: derived -c yields the requested window after PAD256"
    local n eff bad=0
    use_fixture amd
    for n in "${INSTANCE_NAMES[@]}"; do
        load_instance "$n" || { fail "could not load $n"; return; }
        eff=$(effective_ctx_per_request "$INST_TOTAL_CONTEXT" "$INST_PARALLEL_SLOTS" "$INST_KV_UNIFIED")
        if [[ "$eff" != "$INST_CONTEXT_PER_REQUEST" ]]; then
            fail "$n: asked $INST_CONTEXT_PER_REQUEST, llama.cpp would give $eff"
            bad=1
        fi
    done
    ((bad == 0)) && pass "all instances round-trip through PAD256"
}

test_detects_non_round_tripping_config() {
    echo "TEST: a context that cannot round-trip is caught"
    # 1000/3 = 333 -> PAD256 -> 512, not 1000
    local eff
    eff=$(effective_ctx_per_request 1000 3 false)
    if [[ "$eff" == "1000" ]]; then
        fail "padding check is a no-op"
        return
    fi
    pass "PAD256 mismatch detectable (1000/3 -> $eff)"
}

# ── Defaults / override merging ───────────────────────────────────────────────
test_defaults_apply() {
    echo "TEST: an instance without overrides inherits defaults"
    local out
    out=$(render amd base)
    [[ "$(conf_val "$out" THREADS_GEN)" == "12" ]] || { fail "THREADS_GEN not inherited"; return; }
    [[ "$(conf_val "$out" CACHE_TYPE_K)" == "q8_0" ]] || { fail "CACHE_TYPE_K not inherited"; return; }
    [[ "$(conf_val "$out" DRAFT_MAX)" == "16" ]] || { fail "DRAFT_MAX not inherited"; return; }
    pass "defaults inherited"
}

test_overrides_win() {
    echo "TEST: instance values override defaults"
    local out
    out=$(render amd overridden)
    [[ "$(conf_val "$out" THREADS_GEN)" == "8" ]] || { fail "THREADS_GEN override ignored"; return; }
    [[ "$(conf_val "$out" CACHE_TYPE_K)" == "f16" ]] || { fail "CACHE_TYPE_K override ignored"; return; }
    [[ "$(conf_val "$out" DRAFT_MAX)" == "24" ]] || { fail "DRAFT_MAX override ignored"; return; }
    pass "overrides applied"
}

# yq's // operator treats false and "" as absent, so a `false` override of a
# `true` default silently reverted. Regression test.
test_false_override_is_not_swallowed() {
    echo "TEST: a false override of a true default survives"
    local base over
    base=$(conf_val "$(render amd base)" FLASH_ATTN)
    over=$(conf_val "$(render amd overridden)" FLASH_ATTN)
    if [[ "$base" != "true" ]]; then
        fail "default flash_attn:true did not apply (got '$base')"
        return
    fi
    if [[ "$over" != "false" ]]; then
        fail "instance flash_attn:false was swallowed (got '$over')"
        return
    fi
    pass "true default, false override both preserved"
}

test_empty_string_default_is_not_swallowed() {
    echo "TEST: draft_model:\"\" stays empty rather than falling through"
    local out
    out=$(render amd base)
    if [[ -n "$(conf_val "$out" DRAFT_MODEL)" ]]; then
        fail "empty draft_model rendered as '$(conf_val "$out" DRAFT_MODEL)'"
        return
    fi
    [[ "$(conf_val "$(render amd overridden)" DRAFT_MODEL)" == "Draft-B.gguf" ]] \
        || { fail "draft_model override ignored"; return; }
    pass "empty and set draft_model both correct"
}

test_api_key_is_preserved_not_generated() {
    echo "TEST: the rendered conf carries the key it was given"
    local out
    out=$(render amd base)
    [[ "$(conf_val "$out" LLAMA_API_KEY)" == "TESTKEY" ]] \
        || { fail "LLAMA_API_KEY not taken from the target"; return; }
    pass "API key passed through, never invented"
}

# ── Validation ────────────────────────────────────────────────────────────────
expect_reject() {
    local label="$1" expr="$2" out rc cfg
    cfg=$(mktemp --suffix=.yaml)
    yq "$expr" "$FIXTURES/amd.yaml" > "$cfg"
    out=$(LLAMA_CONFIG="$cfg" "$DEPLOY" --render base 2>&1)
    rc=$?
    rm -f "$cfg"
    if ((rc == 0)); then
        fail "$label was accepted but should be rejected"
    else
        pass "$label rejected: $(head -1 <<<"$out" | sed 's/\x1b\[[0-9;]*m//g')"
    fi
}

test_rejects_bad_config() {
    echo "TEST: invalid configs are rejected, not silently deployed"
    expect_reject "ubatch > batch"          '.defaults.ubatch_size = 4096'
    expect_reject "asymmetric cache types"  '.instances.base.cache_type_v = "f16"'
    expect_reject "zero parallel_slots"     '.instances.base.parallel_slots = 0'
    expect_reject "unknown runtime engine"  '.runtime.engine = "containerd"'
    expect_reject "missing context"         'del(.instances.base.context_per_request)'
    expect_reject "missing model_file"      'del(.instances.base.model_file)'
    expect_reject "non-numeric slots"       '.instances.base.parallel_slots = "many"'
}

# llama.cpp force-enables flash attention when the V cache is quantized, so
# flash_attn:false is a no-op there. It must warn, not block: production runs
# this combination and it works.
test_warns_quantized_kv_with_flash_attn_false() {
    echo "TEST: quantized V + flash_attn:false warns but still renders"
    local cfg out rc
    cfg=$(mktemp --suffix=.yaml)
    yq '.instances.base.flash_attn = false' "$FIXTURES/amd.yaml" > "$cfg"
    out=$(LLAMA_CONFIG="$cfg" "$DEPLOY" --render base 2>&1)
    rc=$?
    rm -f "$cfg"

    if ((rc != 0)); then
        fail "a working production combination was rejected"
        return
    fi
    if ! grep -qi 'flash attention' <<<"$out"; then
        fail "no warning that flash_attn:false has no effect"
        return
    fi
    grep -q '^CONTEXT_SIZE=' <<<"$out" || { fail "conf did not render"; return; }
    pass "warned, and still rendered"
}

test_no_warning_when_cache_is_f16() {
    echo "TEST: f16 cache with flash_attn:false warns about nothing"
    local out
    out=$(render amd overridden)   # f16 + flash_attn:false
    if grep -qi 'flash attention' <<<"$out"; then
        fail "spurious flash attention warning for an f16 cache"
        return
    fi
    pass "no warning for f16 + flash_attn:false"
}

# The example is what `make setup` copies and what error messages point at.
# It rots silently otherwise — it was left on the old flat schema once already.
test_example_config_is_valid() {
    echo "TEST: config/llama.example.yaml loads and renders"
    local out rc name
    for name in my-model my-small-model; do
        out=$(LLAMA_CONFIG=config/llama.example.yaml "$DEPLOY" --render "$name" 2>&1)
        rc=$?
        if ((rc != 0)); then
            fail "example config failed to render '$name'"
            sed 's/\x1b\[[0-9;]*m//g' <<<"$out" | head -3
            return
        fi
        grep -q '^CONTEXT_SIZE=' <<<"$out" || { fail "example '$name' produced no CONTEXT_SIZE"; return; }
    done
    pass "example config is valid and renders every instance"
}

test_example_documents_every_key() {
    echo "TEST: the example documents every key load_instance reads"
    local missing=() k
    for k in port model_file context_per_request parallel_slots kv_unified \
             batch_size ubatch_size threads_gen threads_batch threads_http \
             cache_reuse cache_type_k cache_type_v flash_attn draft_model \
             draft_max container_image; do
        grep -qE "^\s*$k:" config/llama.example.yaml || missing+=("$k")
    done
    if ((${#missing[@]} > 0)); then
        fail "example is missing: ${missing[*]}"
        return
    fi
    pass "every key documented"
}

# Config values interpolate into a remote shell string, so quoting is the
# difference between a deploy and a command injection.
test_remote_quoting_is_safe() {
    echo "TEST: _shq neutralises shell metacharacters"
    local out
    out=$(_shq "'; touch /tmp/pwned_shq_test #")
    if [[ -e /tmp/pwned_shq_test ]]; then
        rm -f /tmp/pwned_shq_test
        fail "_shq allowed command execution"
        return
    fi
    # eval of the quoted form must reproduce the literal, not run anything
    local round
    round=$(eval "printf '%s' $out")
    if [[ "$round" != "'; touch /tmp/pwned_shq_test #" ]]; then
        fail "_shq did not round-trip: got '$round'"
        return
    fi
    [[ -e /tmp/pwned_shq_test ]] && { rm -f /tmp/pwned_shq_test; fail "_shq executed on eval"; return; }
    pass "_shq round-trips and executes nothing"
}

test_rejects_flat_legacy_schema() {
    echo "TEST: the old single-instance schema fails with a clear message"
    local cfg out rc
    cfg=$(mktemp --suffix=.yaml)
    printf 'remote: {host: h, user: u}\nruntime: {engine: podman, gpu: amd}\nllama: {context_size: 32768, parallel_slots: 8}\n' > "$cfg"
    out=$(LLAMA_CONFIG="$cfg" "$DEPLOY" --render base 2>&1)
    rc=$?
    rm -f "$cfg"
    if ((rc == 0)); then
        fail "legacy flat schema was accepted"
        return
    fi
    grep -qi 'instances' <<<"$out" || { fail "message does not mention instances"; return; }
    pass "legacy flat schema rejected"
}

# ── Runner ────────────────────────────────────────────────────────────────────
accept_goldens() {
    mkdir -p "$GOLDEN"
    rm -f "$GOLDEN"/*.conf "$GOLDEN"/*.unit 2>/dev/null
    local pair
    for pair in "amd base" "amd overridden" "nvidia shared"; do
        set -- $pair
        render "$1" "$2" > "$GOLDEN/$1.$2.conf"
        echo "wrote $GOLDEN/$1.$2.conf"
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
    for t in test_golden_renders \
             test_context_is_multiplied_not_divided \
             test_kv_unified_is_not_divided \
             test_derivation_round_trips \
             test_detects_non_round_tripping_config \
             test_defaults_apply \
             test_overrides_win \
             test_false_override_is_not_swallowed \
             test_empty_string_default_is_not_swallowed \
             test_api_key_is_preserved_not_generated \
             test_rejects_bad_config \
             test_warns_quantized_kv_with_flash_attn_false \
             test_no_warning_when_cache_is_f16 \
             test_rejects_flat_legacy_schema \
             test_example_config_is_valid \
             test_example_documents_every_key \
             test_remote_quoting_is_safe; do
        "$t"
        echo ""
    done
fi

echo "─────────────────────────────────────────"
echo -e "${GREEN}$PASSED passed${NC}, ${RED}$FAILED failed${NC}"
[[ "$FAILED" -eq 0 ]]
