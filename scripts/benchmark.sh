#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

BENCH_LABEL="${BENCH_LABEL:-current}"
BENCH_OUT="${BENCH_OUT:-bench}"
# Which instance to load. Its slot count sets the VU ceiling.
BENCH_INSTANCE="${BENCH_INSTANCE:-qwen3-14b}"

load_config "${LLAMA_CONFIG:-config/llama.yaml}" || exit 1
load_instance "$BENCH_INSTANCE" || exit 1

if [[ -n "${LLM_ENDPOINT:-}" ]]; then
    : # explicit override wins
elif [[ -n "${LLM_HOST:-}" ]]; then
    LLM_ENDPOINT="https://${LLM_HOST}"
else
    LLM_ENDPOINT="http://${REMOTE_HOST}:8080"
fi

command -v k6 >/dev/null 2>&1 || { echo "k6 not installed" >&2; exit 1; }
mkdir -p "$BENCH_OUT"   # handleSummary will not create directories

export LLM_ENDPOINT LLAMA_API_KEY BENCH_LABEL BENCH_OUT
export LLM_MODEL="$BENCH_INSTANCE"
export LLM_CONTEXT_PER_REQUEST="$INST_CONTEXT_PER_REQUEST"
export LLM_PARALLEL_SLOTS="$INST_PARALLEL_SLOTS"
export LLM_TOTAL_CONTEXT="$INST_TOTAL_CONTEXT"
export BENCH_MAX_VUS="${BENCH_MAX_VUS:-$INST_PARALLEL_SLOTS}"

echo ""
echo "🚀 LLM Server Load Test (k6)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📅 $(date +"%Y-%m-%d %H:%M:%S")"
echo "🌐 Endpoint: ${LLM_ENDPOINT}"
echo "🤖 Instance: ${BENCH_INSTANCE}"
echo "🧠 Context:  ${INST_CONTEXT_PER_REQUEST}/request × ${INST_PARALLEL_SLOTS} slots"
echo "👥 Max VUs:  ${BENCH_MAX_VUS}"
echo "📊 decode-heavy (control) then prefill-heavy (the shape context affects)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

k6 run "$SCRIPT_DIR/benchmark.k6.js"
rc=$?

echo ""
case "$rc" in
    0)   echo "✅ k6 thresholds met" ;;
    99)  echo "❌ k6 SLO thresholds breached" ;;
    104) echo "❌ invalid k6 configuration (not a performance problem)"; exit 2 ;;
    *)   echo "❌ k6 exited $rc"; exit 2 ;;
esac

echo ""
echo "Results: $BENCH_OUT/$BENCH_LABEL.json"
if [[ -f "$BENCH_OUT/baseline.json" && "$BENCH_LABEL" != "baseline" ]]; then
    echo ""
    "$SCRIPT_DIR/compare-baseline.sh" "$BENCH_OUT/baseline.json" "$BENCH_OUT/$BENCH_LABEL.json"
    cmp_rc=$?
    # An SLO breach outranks a baseline regression, and it is the more specific
    # diagnosis: absolute thresholds were missed, not just "slower than last time".
    # `exit $?` here used to discard k6's 99 entirely, so the exit code README
    # documents was unreachable whenever a baseline existed — which is always.
    if ((rc == 99)); then
        echo ""
        echo "Exiting 99 (k6 SLO breach) rather than $cmp_rc (baseline comparison)."
        exit 99
    fi
    exit "$cmp_rc"
fi
if [[ "$BENCH_LABEL" == "baseline" ]]; then
    # Reached by `BENCH_LABEL=baseline make benchmark`, i.e. deliberately
    # (re)recording the baseline. Saying "no baseline yet" here was backwards.
    echo "Recorded as the baseline. Commit $BENCH_OUT/baseline.json to record the trade."
else
    echo "No baseline yet. Accept this run with: make benchmark-accept"
fi
exit "$rc"
