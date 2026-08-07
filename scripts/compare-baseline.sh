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
printf '%-46s %12s %12s %9s  %s\n' METRIC BASELINE CURRENT DELTA VERDICT

cmp_metric() {
    local m="$1" s="$2" dir="$3" tol="$4"
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
        printf "%+.1f%% %s", dl * 100, (ok ? "ok" : "REGRESSION")
    }')
    local delta="${out%% *}" verdict="${out##* }"

    local colour="$GREEN"
    [[ "$verdict" == "REGRESSION" ]] && { colour="$RED"; fail=$((fail + 1)); }
    printf '%-46s %12s %12s %9s  '"$colour"'%s'"$NC"'\n' \
        "$m $s" "$(printf '%.1f' "$b")" "$(printf '%.1f' "$c")" "$delta" "$verdict"
}

# Latency: lower is better. p99 gets a loose band — it needs ~1000 samples to
# stabilise and this profile produces a few hundred.
cmp_metric 'http_req_duration{phase:decode}'  'p(95)' lower  0.10
cmp_metric 'http_req_duration{phase:decode}'  'med'   lower  0.10
cmp_metric 'http_req_duration{phase:prefill}' 'p(95)' lower  0.15
cmp_metric 'http_req_duration{phase:prefill}' 'med'   lower  0.15
cmp_metric 'http_req_duration{phase:decode}'  'p(99)' lower  0.25
cmp_metric 'llm_prompt_ms'                    'p(95)' lower  0.20

# Throughput: higher is better.
cmp_metric 'llm_tokens_per_sec' 'avg'  higher 0.08
cmp_metric 'http_reqs'          'rate' higher 0.10

echo ""
mapfile -t tfails < <(jq -r '.thresholdsFailed[]?' "$CUR")
if ((${#tfails[@]} > 0)); then
    echo -e "${RED}k6 thresholds breached:${NC}"
    printf '  %s\n' "${tfails[@]}"
    fail=$((fail + ${#tfails[@]}))
fi

if ((fail > 0)); then
    echo -e "${RED}$fail regression(s) beyond tolerance${NC}"
    echo "If this is an accepted trade, run: make benchmark-accept"
    exit 1
fi
echo -e "${GREEN}No regressions${NC}"
