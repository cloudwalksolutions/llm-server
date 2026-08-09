#!/bin/bash
# Does a knob in config/llama.yaml actually change what the server serves?
#
# WHY THIS EXISTS
# Before the unit template was vendored, 12 of the 17 variables deploy renders
# into <instances_dir>/<name>.conf had no consumer anywhere in this repo. You
# could add a knob, deploy it, and have it reach nothing — and every offline test
# stayed green, because the goldens only pin what the renderer emits, not what the
# server does with it.
#
# The tempting fix is a text cross-check: every ${VAR} in the unit must match a
# key the renderer writes. That is an implementation test. It passes as long as
# two files agree with each other, even if the flag it produces is misspelled,
# deprecated, ignored by llama.cpp, or silently overridden. So this suite asks
# the only question that matters instead: after a deploy, does the SERVER report
# or exhibit the value?
#
# Knobs with no observable consequence are reported as UNOBSERVABLE rather than
# quietly passing. That list is the real output of this file — it is the set of
# settings nothing can currently prove are working.
#
# READ-ONLY BY DEFAULT. Every check below reads the CURRENT deployed state and
# compares it to config/llama.yaml, so the suite is safe to run any time and is
# effectively a stronger `make verify`. It does not deploy anything.
#
# Usage: ./tests/test-knob-propagation.sh [test-name]
#        INSTANCE=qwen3-14b ./tests/test-knob-propagation.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
# shellcheck source=../scripts/lib/common.sh
source scripts/lib/common.sh

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

load_config "${LLAMA_CONFIG:-config/llama.yaml}" || exit 1
test_ssh || { echo -e "${RED}cannot reach the target${NC}" >&2; exit 1; }

PASSED=0
FAILED=0
UNOBSERVABLE=()
pass() { echo -e "  ${GREEN}PASS${NC} $*"; PASSED=$((PASSED + 1)); }
fail() { echo -e "  ${RED}FAIL${NC} $*"; FAILED=$((FAILED + 1)); }
unobs() { echo -e "  ${YELLOW}UNOBSERVABLE${NC} $*"; UNOBSERVABLE+=("$*"); }

assert_eq() {
    local label="$1" got="$2" want="$3"
    [[ "$got" == "$want" ]] && pass "$label = $got" || fail "$label: want '$want', got '$got'"
}

# ── Per-instance observation ───────────────────────────────────────────────────
check_instance() {
    local name="$1" conf key props slots cmdline pid
    load_instance "$name" >/dev/null || { fail "cannot load $name"; return; }
    conf="$INSTANCES_DIR/$name.conf"
    key=$(remote_conf_value "$conf" LLAMA_API_KEY)

    echo -e "${CYAN}▸ $name${NC}"

    props=$(remote_exec "curl -sf --max-time 15 -H 'Authorization: Bearer $key' http://127.0.0.1:$INST_PORT/props" 2>/dev/null || echo "")
    slots=$(remote_exec "curl -sf --max-time 15 -H 'Authorization: Bearer $key' http://127.0.0.1:$INST_PORT/slots" 2>/dev/null || echo "")
    pid=$(remote_exec "systemctl show -p MainPID --value llama-server@$name" 2>/dev/null | tr -d '\r')
    cmdline=""
    [[ "$pid" =~ ^[0-9]+$ ]] && ((pid != 0)) && \
        cmdline=$(remote_exec "tr '\\0' ' ' < /proc/$pid/cmdline 2>/dev/null" || echo "")

    if [[ -z "$props" ]]; then
        fail "$name: /props unreachable, cannot observe anything"
        return
    fi

    # --- knobs the server reports directly -----------------------------------
    # context_per_request: the whole reason this repo exists. /slots is the
    # authority because it is post-PAD256 and per-slot.
    if [[ -n "$slots" ]] && jq -e 'type=="array"' <<<"$slots" >/dev/null 2>&1; then
        assert_eq "context_per_request -> /slots[].n_ctx" \
            "$(jq -r '[.[].n_ctx] | unique | join(",")' <<<"$slots")" \
            "$INST_CONTEXT_PER_REQUEST"
        assert_eq "parallel_slots -> /slots length" \
            "$(jq -r 'length' <<<"$slots")" "$INST_PARALLEL_SLOTS"
    else
        fail "$name: /slots unreachable"
    fi

    assert_eq "model_file -> /props.model_path" \
        "$(jq -r '.model_path // ""' <<<"$props" | sed 's|.*/||')" "$INST_MODEL_FILE"

    # --- knobs observable only on the live process ---------------------------
    # These prove the conf value became a CLI argument, which is the step that
    # was unverifiable while the unit lived only on the target.
    if [[ -z "$cmdline" ]]; then
        fail "$name: cannot read the live cmdline"
    else
        _arg() { grep -oP "(?:^|\s)$1\s+\K[^ ]+" <<<"$cmdline" | head -1; }
        assert_eq "total context -> live -c"        "$(_arg -c)"  "$INST_TOTAL_CONTEXT"
        assert_eq "parallel_slots -> live -np"      "$(_arg -np)" "$INST_PARALLEL_SLOTS"
        assert_eq "batch_size -> live -b"           "$(_arg -b)"  "$INST_BATCH_SIZE"
        assert_eq "ubatch_size -> live -ub"         "$(_arg -ub)" "$INST_UBATCH_SIZE"
        assert_eq "threads_gen -> live -t"          "$(_arg -t)"  "$INST_THREADS_GEN"
        assert_eq "threads_batch -> live -tb"       "$(_arg -tb)" "$INST_THREADS_BATCH"
        assert_eq "threads_http -> live --threads-http" \
            "$(_arg --threads-http)" "$INST_THREADS_HTTP"
        assert_eq "cache_reuse -> live --cache-reuse" \
            "$(_arg --cache-reuse)" "$INST_CACHE_REUSE"
        assert_eq "cache_type_k -> live --cache-type-k" \
            "$(_arg --cache-type-k)" "$INST_CACHE_TYPE_K"
        assert_eq "cache_type_v -> live --cache-type-v" \
            "$(_arg --cache-type-v)" "$INST_CACHE_TYPE_V"
        assert_eq "container_image -> live argv" \
            "$(grep -oF "$INST_CONTAINER_IMAGE" <<<"$cmdline" | head -1)" \
            "$INST_CONTAINER_IMAGE"

        # flash_attn is the one knob whose NAME lies. false does not pass
        # "-fa off", it passes nothing — so the observable consequence of
        # flash_attn:false is the ABSENCE of -fa, and the resolved state has to
        # come from the journal instead.
        local has_fa resolved
        has_fa=$(grep -cE '(^|\s)-fa(\s|$)' <<<"$cmdline")
        if [[ "$INST_FLASH_ATTN" == "true" ]]; then
            ((has_fa > 0)) && pass "flash_attn:true -> -fa present" \
                            || fail "flash_attn:true but -fa is absent from argv"
        else
            ((has_fa == 0)) && pass "flash_attn:false -> -fa correctly absent" \
                            || fail "flash_attn:false but -fa is in argv"
            resolved=$(remote_exec "journalctl -u llama-server@$name --no-pager 2>/dev/null | grep -oE 'Flash Attention was auto, set to [a-z]+' | tail -1" 2>/dev/null | grep -oE '[a-z]+$')
            echo -e "       ${YELLOW}note${NC} llama.cpp resolved flash attention to '${resolved:-unknown}' anyway"
        fi

        # draft_model empty means speculative decoding off, i.e. no -md.
        if [[ -z "$INST_DRAFT_MODEL" ]]; then
            grep -qE '(^|\s)-md(\s|$)' <<<"$cmdline" \
                && fail "draft_model is empty but -md is in argv" \
                || pass "draft_model:'' -> no -md, speculative decoding off"
        else
            assert_eq "draft_model -> live -md" \
                "$(_arg -md | sed 's|.*/||')" "$INST_DRAFT_MODEL"
            assert_eq "draft_max -> live --draft-max" \
                "$(_arg --draft-max)" "$INST_DRAFT_MAX"
        fi
    fi

    # --- knobs whose effect is behavioural, not reported ---------------------
    # cache_reuse governs whether a prefix that DIVERGES mid-prompt can still be
    # partially reused. Its argv presence is checked above; that it actually
    # reuses is proven by timings.cache_n on a second request, which is what
    # `make bench-agent` measures across a multi-turn session.
    local probe cache_n
    probe="{\"model\":\"$name\",\"max_tokens\":4,\"messages\":[{\"role\":\"user\",\"content\":\"Knob propagation probe. Reply with one word.\"}]}"
    _probe_cache_n() {
        remote_exec "curl -s --max-time 60 -H 'Authorization: Bearer $key' \
            -H 'Content-Type: application/json' -d $(_shq "$probe") \
            http://127.0.0.1:$INST_PORT/v1/chat/completions" 2>/dev/null \
            | jq -r '.timings.cache_n // "none"' 2>/dev/null
    }
    _probe_cache_n >/dev/null   # populate the cache; its own cache_n is not the signal
    cache_n=$(_probe_cache_n)   # the repeat is what must show reuse
    if [[ "$cache_n" =~ ^[0-9]+$ ]] && ((cache_n > 0)); then
        pass "prompt caching is live (repeat of an identical prompt reused $cache_n tokens)"
    else
        fail "a repeated identical prompt reused nothing (cache_n=$cache_n)"
    fi

    # --- knobs nothing can observe -------------------------------------------
    # Recorded rather than skipped: this is the list of settings that could be
    # wrong without any test noticing.
    unobs "$name: kv_unified — only distinguishable from its effect on the derived -c, which is already asserted"
    echo ""
}

test_every_knob_reaches_the_server() {
    local only="${INSTANCE:-}" n
    for n in "${INSTANCE_NAMES[@]}"; do
        [[ -n "$only" && "$n" != "$only" ]] && continue
        check_instance "$n"
    done
}

# The unit template is the argv. If the target's copy has drifted from the
# repo's, then the repo no longer describes what is running, and every assertion
# above is about a file this project does not control.
test_target_unit_matches_the_repo() {
    echo -e "${CYAN}▸ unit template${NC}"
    local live rendered
    live=$(remote_exec "cat $UNIT_PATH 2>/dev/null" || echo "")
    rendered=$(./scripts/deploy-llama.sh --render unit 2>/dev/null || echo "")
    if [[ -z "$rendered" ]]; then
        fail "could not render the unit template locally"
    elif [[ -z "$live" ]]; then
        fail "no unit at $UNIT_PATH on the target"
    elif [[ "$live" == "$rendered" ]]; then
        pass "target $UNIT_PATH matches templates/llama-server@.service.in"
    else
        # Comments-only drift is worth distinguishing from argv drift.
        if diff <(grep -vE '^\s*(#|$)' <<<"$live") <(grep -vE '^\s*(#|$)' <<<"$rendered") >/dev/null; then
            fail "unit differs from the repo in comments only — run 'make deploy' to sync"
        else
            fail "unit ARGV differs from the repo — the repo does not describe what is running"
            diff <(grep -vE '^\s*(#|$)' <<<"$live") <(grep -vE '^\s*(#|$)' <<<"$rendered") \
                | head -12 | sed 's/^/       /'
        fi
    fi
    echo ""
}

echo -e "${BLUE}Knob propagation — does config reach the running server?${NC}"
echo -e "  target: $REMOTE_USER@$REMOTE_HOST"
echo -e "  ${YELLOW}read-only${NC}: compares the CURRENT deployed state to config/llama.yaml"
echo ""

if [[ $# -ge 1 ]]; then
    declare -F "$1" >/dev/null || { echo -e "${RED}no such test: $1${NC}" >&2; exit 2; }
    "$1"
else
    test_target_unit_matches_the_repo
    test_every_knob_reaches_the_server
fi

if ((${#UNOBSERVABLE[@]} > 0)); then
    echo -e "${YELLOW}Unobservable knobs${NC} — nothing here can prove these are in effect:"
    printf '  - %s\n' "${UNOBSERVABLE[@]}"
    echo ""
fi

echo "─────────────────────────────────────────"
echo -e "${GREEN}$PASSED passed${NC}, ${RED}$FAILED failed${NC}, ${YELLOW}${#UNOBSERVABLE[@]} unobservable${NC}"
[[ "$FAILED" -eq 0 ]]
