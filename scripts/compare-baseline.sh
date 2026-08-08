#!/usr/bin/env bash
# Compare a k6 run against a stored baseline and fail on regression.
#
# k6's own thresholds are absolute SLOs ("p95 must never exceed 30s"). They
# don't catch "p95 went from 3.1s to 4.4s". This does.
#
# Usage: ./scripts/compare-baseline.sh [baseline.json] [current.json]
# Exit:  0 no regression | 1 regression | 3 inconclusive (too few samples)
set -uo pipefail

BASE="${1:-bench/baseline.json}"
CUR="${2:-bench/current.json}"
MIN_ITER="${MIN_ITER:-100}"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

[[ -f "$CUR" ]] || { echo "No current run at $CUR" >&2; exit 2; }

if [[ ! -f "$BASE" ]]; then
    mkdir -p "$(dirname "$BASE")"
    cp "$CUR" "$BASE"
    echo -e "${YELLOW}No baseline; seeded $BASE from this run.${NC}"
    exit 0
fi

iters=$(jq -r '.metrics.iterations.values.count // 0' "$CUR")
if (($(printf '%.0f' "$iters") < MIN_ITER)); then
    echo -e "${RED}INCONCLUSIVE${NC}: only $iters iterations (need $MIN_ITER)"
    exit 3
fi

# Comparing across different server configs is meaningless.
for k in contextPerRequest parallelSlots model; do
    b=$(jq -r ".env.$k // \"\"" "$BASE")
    c=$(jq -r ".env.$k // \"\"" "$CUR")
    if [[ -n "$b" && "$b" != "$c" ]]; then
        echo -e "${YELLOW}NOTE${NC}: baseline $k=$b, current $k=$c — expect movement."
    fi
done
echo ""

fail=0
advisory=0
printf '%-46s %12s %12s %9s  %s\n' METRIC BASELINE CURRENT DELTA VERDICT

# mode: "gate" fails the build, "advisory" reports but does not.
cmp_metric() {
    local m="$1" s="$2" dir="$3" tol="$4" mode="${5:-gate}"
    local b c out
    b=$(jq -r --arg m "$m" --arg s "$s" '.metrics[$m].values[$s] // "null"' "$BASE")
    c=$(jq -r --arg m "$m" --arg s "$s" '.metrics[$m].values[$s] // "null"' "$CUR")

    if [[ "$b" == "null" || "$c" == "null" ]]; then
        printf '%-46s %12s %12s %9s  %s\n' "$m $s" "$b" "$c" "-" "SKIP"
        return
    fi

    out=$(awk -v b="$b" -v c="$c" -v d="$dir" -v t="$tol" 'BEGIN{
        dl = (b == 0) ? 0 : (c - b) / b
        ok = (d == "lower") ? (c <= b * (1 + t)) : (c >= b * (1 - t))
        printf "%+.1f%% %s", dl * 100, (ok ? "ok" : "OVER")
    }')
    local delta="${out%% *}" verdict="${out##* }"

    local colour="$GREEN"
    if [[ "$verdict" == "OVER" ]]; then
        if [[ "$mode" == "gate" ]]; then
            colour="$RED"; verdict="REGRESSION"; fail=$((fail + 1))
        else
            colour="$YELLOW"; verdict="slower"; advisory=$((advisory + 1))
        fi
    fi
    printf '%-46s %12s %12s %9s  '"$colour"'%s'"$NC"'\n' \
        "$m $s" "$(printf '%.1f' "$b")" "$(printf '%.1f' "$c")" "$delta" "$verdict"
}

# Correctness. These are stable run to run, so they gate hard.
cmp_rate_gate() {
    local m="$1" label="$2" c
    c=$(jq -r --arg m "$m" '.metrics[$m].values.rate // 0' "$CUR")
    if awk -v c="$c" 'BEGIN{exit !(c > 0)}'; then
        printf '%-46s %12s %12s %9s  '"$RED"'FAIL'"$NC"'\n' "$label" "0" "$c" "-"
        fail=$((fail + 1))
    else
        printf '%-46s %12s %12s %9s  '"$GREEN"'ok'"$NC"'\n' "$label" "0" "$c" "-"
    fi
}

# Correctness first. These don't drift with load, so a change here is real.
cmp_rate_gate 'http_req_failed{phase:decode}'  'http failures (decode)'
cmp_rate_gate 'http_req_failed{phase:prefill}' 'http failures (prefill)'
cmp_rate_gate 'llm_context_errors'             'context overflow errors'

# Latency and throughput are ADVISORY on this hardware. Two back-to-back runs
# with an identical server config moved decode med by +34% while prefill med
# moved -15% — opposite directions, so the run-to-run noise floor exceeds any
# tolerance tight enough to be useful as a gate. They're reported, not enforced.
#
# To make these gate meaningfully: run the benchmark 5+ times unchanged, take
# the spread, and set each band to ~2x it. Bands below are a rough placeholder
# sized from two observations, deliberately wide.
cmp_metric 'http_req_duration{phase:decode}'  'p(95)' lower  0.40 advisory
cmp_metric 'http_req_duration{phase:decode}'  'med'   lower  0.40 advisory
cmp_metric 'http_req_duration{phase:prefill}' 'p(95)' lower  0.40 advisory
cmp_metric 'http_req_duration{phase:prefill}' 'med'   lower  0.40 advisory
cmp_metric 'llm_prompt_ms'                    'p(95)' lower  0.40 advisory
cmp_metric 'llm_tokens_per_sec' 'avg'  higher 0.30 advisory
cmp_metric 'http_reqs'          'rate' higher 0.30 advisory

echo ""
mapfile -t tfails < <(jq -r '.thresholdsFailed[]?' "$CUR")
if ((${#tfails[@]} > 0)); then
    echo -e "${RED}k6 thresholds breached:${NC}"
    printf '  %s\n' "${tfails[@]}"
    fail=$((fail + ${#tfails[@]}))
fi

if ((fail > 0)); then
    echo -e "${RED}$fail hard failure(s)${NC}"
    echo "If this is an accepted trade, run: make benchmark-accept"
    exit 1
fi
if ((advisory > 0)); then
    echo -e "${YELLOW}No failures. $advisory metric(s) slower than baseline —"
    echo -e "advisory only; re-run before drawing a conclusion.${NC}"
    exit 0
fi
echo -e "${GREEN}No regressions${NC}"
