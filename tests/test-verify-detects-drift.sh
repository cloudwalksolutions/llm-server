#!/bin/bash
# Does `make verify` actually FAIL when the target disagrees with the config?
#
# verify-deploy.sh is the thing standing between a drifted target and a green
# build, and nothing tested that it can go red. A regression that made it report
# PASS unconditionally — a swallowed exit status, a helper returning its default
# on success, a jq filter that yields empty for both sides — would look exactly
# like a healthy fleet.
#
# So: build a single-instance config that matches reality, prove verify passes,
# then mutate one field at a time and prove verify fails for each. This covers
# remote_conf_value, the live-cmdline read, /props, and /slots by their effect
# rather than by poking at their internals.
#
# Needs SSH to the target. Read-only: it never writes to the target, only reads.
#
# Usage: ./tests/test-verify-detects-drift.sh [test-name]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
# shellcheck source=../scripts/lib/common.sh
source scripts/lib/common.sh

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

VERIFY="./scripts/verify-deploy.sh"
REAL_CONFIG="${LLAMA_CONFIG:-config/llama.yaml}"
# One instance keeps the runtime down — each verify run makes a real tool call.
INSTANCE="${DRIFT_INSTANCE:-qwen3-14b}"

PASSED=0
FAILED=0
pass() { echo -e "${GREEN}PASS${NC}: $*"; PASSED=$((PASSED + 1)); }
fail() { echo -e "${RED}FAIL${NC}: $*"; FAILED=$((FAILED + 1)); }

load_config "$REAL_CONFIG" >/dev/null 2>&1 || {
    echo -e "${RED}cannot load $REAL_CONFIG${NC}" >&2; exit 1; }
test_ssh || { echo -e "${RED}cannot reach the target${NC}" >&2; exit 1; }

BASE=$(mktemp --suffix=.yaml)
trap 'rm -f "$BASE" "${MUT:-}"' EXIT
# Keep only the instance under test, so verify does not spend a tool call on
# instances this suite is not asserting about.
yq ".instances |= with_entries(select(.key == \"$INSTANCE\"))" "$REAL_CONFIG" > "$BASE"

# Returns 0 if verify passed, 1 if it failed. Output captured either way.
run_verify() {
    local cfg="$1"
    VERIFY_OUT=$(LLAMA_CONFIG="$cfg" "$VERIFY" 2>&1)
    return $?
}

# The control. If this fails, every drift assertion below is meaningless —
# verify would be "detecting" drift that isn't there.
test_verify_passes_when_config_matches_target() {
    echo "TEST: verify passes against an accurate config"
    if run_verify "$BASE"; then
        pass "accurate config verifies clean ($(grep -oE '[0-9]+ passed' <<<"$VERIFY_OUT" | head -1))"
    else
        fail "verify failed on an accurate config — the control is broken"
        sed 's/\x1b\[[0-9;]*m//g' <<<"$VERIFY_OUT" | grep -E '^\s+FAIL' | head -5
    fi
}

# Each mutation is a real drift shape: someone edited llama.yaml and did not
# deploy, or a deploy half-applied.
expect_drift_detected() {
    local label="$1" expr="$2" want_signal="$3"
    MUT=$(mktemp --suffix=.yaml)
    yq "$expr" "$BASE" > "$MUT"

    if run_verify "$MUT"; then
        fail "$label: verify reported success against a drifted target"
        rm -f "$MUT"; return
    fi
    # Failing for the right reason matters — a config so broken it cannot load
    # would also be non-zero, and would prove nothing about drift detection.
    if ! grep -qE "FAIL.*$want_signal" <<<"$(sed 's/\x1b\[[0-9;]*m//g' <<<"$VERIFY_OUT")"; then
        fail "$label: verify failed, but not on '$want_signal'"
        sed 's/\x1b\[[0-9;]*m//g' <<<"$VERIFY_OUT" | grep -E '^\s+FAIL' | head -3
        rm -f "$MUT"; return
    fi
    pass "$label detected"
    rm -f "$MUT"
}

test_verify_detects_drift() {
    echo "TEST: verify fails when the target disagrees with the config"

    # Halving the window changes CONTEXT_SIZE, the live -c, /props and /slots at
    # once — the exact shape of the 2816-token bug.
    expect_drift_detected "context_per_request drift" \
        ".instances.$INSTANCE.context_per_request = 8192" "CONTEXT_SIZE"

    # Slot count drift is what silently divided the window in the first place.
    expect_drift_detected "parallel_slots drift" \
        ".instances.$INSTANCE.parallel_slots = 4" "PARALLEL_SLOTS"

    # KV type drift would otherwise only show up as a quality change.
    expect_drift_detected "cache_type drift" \
        ".instances.$INSTANCE.cache_type_k = \"f16\" | .instances.$INSTANCE.cache_type_v = \"f16\"" \
        "CACHE_TYPE_K"

    # Serving a different model than the config claims.
    expect_drift_detected "model_file drift" \
        ".instances.$INSTANCE.model_file = \"Qwen3-8B-Q4_K_M.gguf\"" "MODEL_FILE"

    # A port nothing is listening on: /props, /slots and the tool call all fail,
    # and the router map disagrees too.
    expect_drift_detected "port drift" \
        ".instances.$INSTANCE.port = 8099" "backend"
}

echo -e "${BLUE}verify drift-detection tests${NC}"
echo -e "  target:   $REMOTE_USER@$REMOTE_HOST"
echo -e "  instance: $INSTANCE"
echo -e "  ${YELLOW}note:${NC} each case runs a full verify, including a real tool call"
echo ""

if [[ $# -ge 1 ]]; then
    declare -F "$1" >/dev/null || { echo -e "${RED}no such test: $1${NC}" >&2; exit 2; }
    "$1"
else
    test_verify_passes_when_config_matches_target
    echo ""
    test_verify_detects_drift
    echo ""
fi

echo "─────────────────────────────────────────"
echo -e "${GREEN}$PASSED passed${NC}, ${RED}$FAILED failed${NC}"
[[ "$FAILED" -eq 0 ]]
