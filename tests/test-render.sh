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

# The behaviour that matters is that deploy REFUSES such a config, not that a
# helper computes a number. 16000 x 4 = 64000, which divides back to 16000 but
# PAD256s up to 16128 — so the config would silently serve a window 128 tokens
# wider than it asked for. This is the reachable failure shape; the derivation
# guard runs only in --check/--dry-run/apply, never in --render.
test_refuses_a_window_it_cannot_deliver() {
    echo "TEST: deploy refuses a context that cannot survive PAD256"
    local cfg out rc
    cfg=$(mktemp --suffix=.yaml)
    yq '.instances.base.context_per_request = 16000' "$FIXTURES/amd.yaml" > "$cfg"
    out=$(LLAMA_CONFIG="$cfg" "$DEPLOY" --check 2>&1)
    rc=$?
    rm -f "$cfg"
    if ((rc == 0)); then
        fail "16000/request was accepted; llama.cpp would serve 16128"
        return
    fi
    grep -q '16128' <<<"$out" || { fail "message does not name the window actually served"; return; }
    pass "refused: $(sed 's/\x1b\[[0-9;]*m//g' <<<"$out" | head -1)"
}

test_accepts_a_window_it_can_deliver() {
    echo "TEST: the guard is not simply refusing everything"
    local out rc
    out=$(LLAMA_CONFIG="$FIXTURES/amd.yaml" "$DEPLOY" --check 2>&1)
    rc=$?
    if ((rc != 0)); then
        fail "a valid config was refused: $(sed 's/\x1b\[[0-9;]*m//g' <<<"$out" | head -1)"
        return
    fi
    pass "valid config passes --check"
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

# Every config below rendered and deployed cleanly before this suite existed.
# Each one breaks the target in a way that only surfaces as a failed health
# check minutes later, or — for the last two — not at all.
test_rejects_configs_that_break_the_target() {
    echo "TEST: configs that would break the running server are refused"

    # A typo'd cache type deploys fine, then the container refuses to start and
    # the deploy burns its full 300s health-check timeout per instance.
    expect_reject "misspelled cache_type" \
        '.instances.base.cache_type_k = "q8-0" | .instances.base.cache_type_v = "q8-0"'

    # Renders CONTAINER_IMAGE=null, which podman reports as an opaque error.
    expect_reject "missing container_image" 'del(.defaults.container_image)'

    # One instance wins the bind; the other crash-loops. The router-map check
    # only compares each name against its own port, so nothing else sees this.
    expect_reject "two instances on one port" '.instances.overridden.port = 8082'

    # Names interpolate into a yq expression and a remote `sudo bash -c`. A
    # quote here produced a wall of yq lexer errors rather than a config error.
    expect_reject "instance name with a quote" \
        '.instances["bad\"name"] = .instances.base'
    expect_reject "instance name with a space" \
        '.instances["bad name"] = .instances.base'

    # systemd's EnvironmentFile is line-oriented and last-wins, and
    # CONTAINER_IMAGE is the last line rendered — so a newline in a value can
    # append LLAMA_API_KEY= and silently disable auth.
    expect_reject "newline in model_file" \
        '.instances.base.model_file = "A.gguf
EVIL=1"'
    expect_reject "newline in container_image" \
        '.defaults.container_image = "img:tag
LLAMA_API_KEY="'
}

# llama.cpp's own default for --cache-reuse is 0 (disabled). The schema could
# not express it, because the validator rejected every non-positive integer.
test_accepts_zero_where_llama_cpp_means_disabled() {
    echo "TEST: cache_reuse:0 and draft_max:0 are legal, not errors"
    local cfg out rc
    cfg=$(mktemp --suffix=.yaml)
    yq '.defaults.cache_reuse = 0 | .defaults.draft_max = 0' "$FIXTURES/amd.yaml" > "$cfg"
    out=$(LLAMA_CONFIG="$cfg" "$DEPLOY" --render base 2>&1)
    rc=$?
    rm -f "$cfg"
    if ((rc != 0)); then
        fail "zero was rejected: $(sed 's/\x1b\[[0-9;]*m//g' <<<"$out" | head -1)"
        return
    fi
    [[ "$(conf_val "$out" CACHE_REUSE)" == "0" ]] || { fail "CACHE_REUSE did not render as 0"; return; }
    pass "0 accepted and rendered for both"
}

# But a negative or non-numeric value still has to fail.
test_still_rejects_non_integers_where_zero_is_allowed() {
    echo "TEST: relaxing to unsigned did not relax to anything"
    expect_reject "negative cache_reuse"    '.defaults.cache_reuse = -1'
    expect_reject "non-numeric cache_reuse" '.defaults.cache_reuse = "lots"'
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

test_agent_gate_fails_a_run_that_stopped_early() {
    echo "TEST: the agent benchmark passes only when every planned turn ran clean"
    local result
    result=$(mktemp)
    echo '{"correctness":{"turns":1,"httpErrors":0}}' > "$result"
    if agent_gate "$result" 24 >/dev/null; then
        fail "a run that stopped after 1 of 24 turns passed"
    else
        pass "a run that stopped early fails"
    fi
    echo '{"correctness":{"turns":24,"httpErrors":0}}' > "$result"
    if agent_gate "$result" 24 >/dev/null; then
        pass "a complete clean run passes"
    else
        fail "a complete clean run failed"
    fi
    rm -f "$result"
}

test_sudo_gets_the_password_over_key_auth() {
    echo "TEST: key auth still feeds SSH_PASS to sudo, which has no tty to prompt on"
    local sent quoted
    quoted=$(_shq "pa ss'word")
    sent=$(
        _ssh_run() { printf '%s' "${*: -1}"; }
        SSH_AUTH=key SSH_PASS="pa ss'word" REMOTE_USER=u REMOTE_HOST=h
        remote_exec_sudo "true"
    )
    if [[ "$sent" == *"| sudo -S bash -c"* && "$sent" == *"$quoted"* ]]; then
        pass "key auth pipes the password to sudo -S"
    else
        fail "key auth ran: $sent"
    fi
}

# ── Unit template ─────────────────────────────────────────────────────────────
render_unit() { LLAMA_CONFIG="$FIXTURES/$1.yaml" "$DEPLOY" --render unit 2>&1; }

# The unit is the argv. A placeholder that survives rendering installs a unit
# systemd cannot start, and the failure would land as an opaque container error
# minutes into a deploy.
test_unit_renders_with_nothing_left_unresolved() {
    echo "TEST: the rendered unit has no unresolved placeholders"
    local out fixture bad=0
    for fixture in amd nvidia; do
        out=$(render_unit "$fixture")
        if grep -q '@[A-Z_]\+@' <<<"$out"; then
            fail "$fixture: unresolved $(grep -o '@[A-Z_]\+@' <<<"$out" | sort -u | tr '\n' ' ')"
            bad=1
        elif ! grep -q '^\[Service\]' <<<"$out"; then
            fail "$fixture: output is not a systemd unit"
            bad=1
        fi
    done
    ((bad == 0)) && pass "both fixtures render a complete unit"
}

# runtime.engine and runtime.gpu have to reach the argv, or the unit would launch
# the wrong container runtime with the wrong device flags.
test_unit_reflects_engine_and_gpu() {
    echo "TEST: runtime.engine and runtime.gpu change the rendered argv"
    local amd nvidia
    amd=$(render_unit amd)
    nvidia=$(render_unit nvidia)

    grep -q '/usr/bin/podman run' <<<"$amd"    || { fail "amd fixture did not render podman"; return; }
    grep -q -- '--device /dev/kfd' <<<"$amd"   || { fail "amd fixture lost the AMD devices"; return; }
    grep -q -- '--gpus all' <<<"$amd"          && { fail "amd fixture rendered NVIDIA flags"; return; }

    grep -q '/usr/bin/docker run' <<<"$nvidia" || { fail "nvidia fixture did not render docker"; return; }
    grep -q -- '--gpus all' <<<"$nvidia"       || { fail "nvidia fixture lost --gpus all"; return; }
    grep -q -- '--device /dev/kfd' <<<"$nvidia" && { fail "nvidia fixture rendered AMD devices"; return; }

    # The CUDA server image has llama-server as its ENTRYPOINT, so repeating the
    # command word there would be parsed as a model argument.
    grep -qE '^\s+llama-server \\' <<<"$amd" || { fail "amd fixture lost the llama-server command word"; return; }
    grep -qE '^\s+llama-server \\' <<<"$nvidia" && { fail "nvidia fixture must not name llama-server (it is the ENTRYPOINT)"; return; }

    pass "engine, GPU flags and command word all follow runtime.*"
}

# Upstream removed --no-mmap; a server passed it refuses to start.
test_unit_loads_models_without_mmap_by_its_current_name() {
    echo "TEST: the unit disables mmap with --load-mode none, not the removed --no-mmap"
    local unit
    unit=$(render_unit amd)
    grep -q -- '--no-mmap' <<<"$unit" && { fail "unit still passes the removed --no-mmap"; return; }
    grep -q -- '-lm none' <<<"$unit"  || { fail "unit does not pass -lm none"; return; }
    pass "mmap disabled by -lm none"
}

# Current llama.cpp takes -fa on|off|auto; a bare -fa swallows the next flag as its value.
test_unit_gives_flash_attention_a_value() {
    echo "TEST: flash_attn: true renders -fa on"
    local unit
    unit=$(render_unit amd)
    grep -q 'FA_ARG="-fa on"' <<<"$unit" || { fail "unit renders a bare -fa"; return; }
    pass "flash attention flag carries its value"
}

# resources: was dead config until deploy owned the unit. Assert it lands.
test_unit_carries_resource_limits() {
    echo "TEST: resources: reaches the unit's Limit* directives"
    local cfg out
    cfg=$(mktemp --suffix=.yaml)
    yq '.resources.limit_nofile = 4242 | .resources.limit_memlock = "unlimited"' \
        "$FIXTURES/amd.yaml" > "$cfg"
    out=$(LLAMA_CONFIG="$cfg" "$DEPLOY" --render unit 2>&1)
    rm -f "$cfg"
    grep -q '^LimitNOFILE=4242$'      <<<"$out" || { fail "limit_nofile did not reach LimitNOFILE"; return; }
    grep -q '^LimitMEMLOCK=unlimited$' <<<"$out" || { fail "limit_memlock did not reach LimitMEMLOCK"; return; }
    pass "both limits rendered"
}

# Per-instance values must NOT be baked into the shared unit — they belong in the
# per-model conf that systemd expands. Baking one in would silently give every
# instance the first instance's setting.
test_unit_leaves_per_instance_values_to_systemd() {
    echo "TEST: the shared unit references \${VAR}, never a concrete instance value"
    local out
    out=$(render_unit amd)
    grep -q -- '-c ${CONTEXT_SIZE}' <<<"$out" || { fail "-c was not left as \${CONTEXT_SIZE}"; return; }
    grep -q -- '-np ${PARALLEL_SLOTS}' <<<"$out" || { fail "-np was not left as \${PARALLEL_SLOTS}"; return; }
    # 65536 is amd/base's derived total; finding it here would mean it got baked in.
    if grep -qE -- '-c[[:space:]]+[0-9]+' <<<"$out"; then
        fail "a literal -c value was baked into the shared unit"
        return
    fi
    grep -q '%i' <<<"$out" || { fail "the systemd instance placeholder %i was lost"; return; }
    pass "per-instance values stay as \${VAR} / %i"
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

# Without this guard a typo'd test name printed "command not found" and the
# suite exited 0 having run nothing.
if [[ $# -ge 1 ]]; then
    declare -F "$1" >/dev/null || { echo -e "${RED}no such test: $1${NC}" >&2; exit 2; }
    "$1"
else
    for t in test_golden_renders \
             test_context_is_multiplied_not_divided \
             test_kv_unified_is_not_divided \
             test_derivation_round_trips \
             test_refuses_a_window_it_cannot_deliver \
             test_accepts_a_window_it_can_deliver \
             test_defaults_apply \
             test_overrides_win \
             test_false_override_is_not_swallowed \
             test_empty_string_default_is_not_swallowed \
             test_api_key_is_preserved_not_generated \
             test_rejects_bad_config \
             test_rejects_configs_that_break_the_target \
             test_accepts_zero_where_llama_cpp_means_disabled \
             test_still_rejects_non_integers_where_zero_is_allowed \
             test_warns_quantized_kv_with_flash_attn_false \
             test_no_warning_when_cache_is_f16 \
             test_unit_renders_with_nothing_left_unresolved \
             test_unit_reflects_engine_and_gpu \
             test_unit_carries_resource_limits \
             test_unit_leaves_per_instance_values_to_systemd \
             test_rejects_flat_legacy_schema \
             test_example_config_is_valid \
             test_example_documents_every_key \
             test_remote_quoting_is_safe \
             test_agent_gate_fails_a_run_that_stopped_early \
             test_sudo_gets_the_password_over_key_auth \
             test_unit_loads_models_without_mmap_by_its_current_name \
             test_unit_gives_flash_attention_a_value; do
        "$t"
        echo ""
    done
fi

echo "─────────────────────────────────────────"
echo -e "${GREEN}$PASSED passed${NC}, ${RED}$FAILED failed${NC}"
[[ "$FAILED" -eq 0 ]]
