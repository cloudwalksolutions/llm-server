#!/usr/bin/env bash
# Benchmark the workload the app actually runs: streamed, tool-calling, multi-turn.
#
# WHY THIS EXISTS ALONGSIDE `make benchmark`
# The k6 harness measures a single-turn, non-streaming, tool-free request with a
# ~1200-token prompt. The consuming app streams via SSE,
# passes a web_search tool whose arguments must be schema-shaped JSON, and grows
# conversation history across turns. So the existing benchmark cannot regress on
# any of the things that actually break, and pointed at the agent's own instance
# it can never even reach its 100-iteration floor (parallel_slots: 1 -> 1 VU).
#
# WHAT IT GATES ON
# Correctness rates, not latency. Tool-argument JSON validity and streaming
# behaviour are binary, so they make a gate that cannot flake. Latency stays
# advisory here for the same reason the k6 harness already demoted it: two
# back-to-back runs on identical config moved decode median +34% while prefill
# moved -15% (scripts/compare-baseline.sh).
#
# DETERMINISM
# Turns replay from tests/fixtures/agent-session.json, and the history appended
# between turns is the RECORDED assistant/tool message, never the model's live
# output. Same prompt prefix every run, so cache behaviour and percentiles are
# comparable. temperature 0 is deliberately NOT used: Qwen documents greedy
# decoding as degrading this model and warns it can cause repetition loops, so
# the correctness arms use Qwen's recommended non-thinking sampler with a fixed
# seed instead.
#
# COLD CACHE
# POST /slots/{id}?action=erase returns 501 on this target (no --slot-save-path),
# so a cold measurement cannot erase the cache. Instead each cold session gets a
# unique nonce in its system message, which defeats prefix matching — and that is
# verified from timings rather than assumed. The check is a ratio, not
# `cache_n == 0`: the chat template's own preamble tokens always match, so a
# genuinely cold turn still reports a cache_n of 1 or 2.
#
# Usage:
#   ./scripts/bench-agent.sh                    run against BENCH_INSTANCE
#   BENCH_INSTANCE=qwen3-14b-1m ./scripts/bench-agent.sh
#   BENCH_ITERATIONS=5 ./scripts/bench-agent.sh
#   BENCH_EXTRA='{"chat_template_kwargs":{"enable_thinking":false}}' ./scripts/bench-agent.sh
#   BENCH_SAMPLER=server BENCH_TOOL_CHOICE=turn BENCH_REPLAY_REASONING=1 ./scripts/bench-agent.sh
#   ./scripts/bench-agent.sh --accept           promote this run to the baseline
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/agent-judge.sh
source "$SCRIPT_DIR/lib/agent-judge.sh"

ACCEPT=0
case "${1:-}" in
    --accept) ACCEPT=1 ;;
    "")       ;;
    *) echo "Unknown option: $1" >&2
       echo "Usage: $0 [--accept]" >&2
       exit 2 ;;
esac

load_config "${LLAMA_CONFIG:-config/llama.yaml}" || exit 1

# Default to the instance the tool-using agent actually uses. The k6 harness
# defaults to qwen3-14b, which is the coach (no tools) — the wrong target for
# this suite.
BENCH_INSTANCE="${BENCH_INSTANCE:-qwen3-14b-1m}"
FIXTURE="${FIXTURE:-tests/fixtures/agent-session.json}"
ITERATIONS="${BENCH_ITERATIONS:-3}"
# 256 is not generous. With thinking active the model can spend an entire small
# budget on reasoning_content and never reach the tool call — measured here at 200.
# Raise this rather than lowering it if turns fail with finish=length.
MAX_TOKENS="${BENCH_MAX_TOKENS:-768}"
SEED="${BENCH_SEED:-0}"
OUT_DIR="${BENCH_OUT_DIR:-bench}"
LABEL="${BENCH_LABEL:-agent-current}"
BASELINE="${BENCH_BASELINE:-$OUT_DIR/agent-baseline.json}"

# Merged into every request, the way a consumer asks for thinking off or a reasoning effort.
EXTRA="${BENCH_EXTRA:-"{}"}"
jq -e 'type == "object"' <<<"$EXTRA" >/dev/null 2>&1 || {
    echo -e "${RED}BENCH_EXTRA must be a JSON object${NC}" >&2; exit 2; }
# client: Qwen's non-thinking sampler on every request. server: none, so each instance's own
# applies, which is the only fair way to compare models.
SAMPLER="${BENCH_SAMPLER:-client}"
TEMP="${BENCH_TEMP:-0.7}"
TOP_P="${BENCH_TOP_P:-0.8}"
TOP_K="${BENCH_TOP_K:-20}"
# auto: the model decides. turn: required on tool turns, none on answer turns.
TOOL_CHOICE="${BENCH_TOOL_CHOICE:-auto}"
# 1: send each turn's live reasoning_content back with the recorded history, as a client on
# llama.cpp's preserved-thinking path does.
REPLAY_REASONING="${BENCH_REPLAY_REASONING:-0}"

[[ -f "$FIXTURE" ]] || { echo -e "${RED}no fixture at $FIXTURE${NC}" >&2; exit 1; }
command -v jq >/dev/null || { echo -e "${RED}jq is required${NC}" >&2; exit 1; }

load_instance "$BENCH_INSTANCE" >/dev/null || {
    echo -e "${RED}no such instance: $BENCH_INSTANCE${NC}" >&2; exit 1; }
PORT="$INST_PORT"
test_ssh || { echo -e "${RED}cannot reach target${NC}" >&2; exit 1; }
KEY=$(remote_conf_value "$INSTANCES_DIR/$BENCH_INSTANCE.conf" LLAMA_API_KEY)
[[ -n "$KEY" ]] || { echo -e "${RED}could not read the API key for $BENCH_INSTANCE${NC}" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

SYSTEM=$(jq -r '.system' "$FIXTURE")
TOOLS=$(jq -c '.tools' "$FIXTURE")
N_TURNS=$(jq -r '.turns | length' "$FIXTURE")

# ── Counters ──────────────────────────────────────────────────────────────────
# Correctness counters are what gate. Anything non-zero in a *_bad counter fails.
declare -i n_turns=0 n_http_bad=0 n_stream_bad=0 n_toolcall_missing=0
declare -i n_toolargs_bad=0 n_schema_bad=0 n_finish_bad=0 n_cold_not_cold=0
declare -i n_warm_not_warm=0 n_reasoning_ate_budget=0 n_wrong_tool=0 n_unexpected_call=0
TTFT_MS=(); PROMPT_MS=(); GEN_TPS=(); HIT_RATIO=(); PROXY_MS=()

# ── One streamed turn ─────────────────────────────────────────────────────────
# Streams over ssh, timestamping the first content-bearing frame client-side so
# TTFT includes the transport the app actually pays for, while server-side
# timings come from the response itself.
stream_turn() {
    local body="$1" out="$WORK/turn.sse" tf="$WORK/tfirst"
    : > "$out"; : > "$tf"

    # TTFT has to be stamped WHILE the stream arrives. Reading the file after
    # curl exits would time our own parsing and report something close to total
    # latency, which is the one thing TTFT is supposed to distinguish itself from.
    #
    # The first content frame is detected with case globs rather than jq so this
    # costs no process per frame; `date` is spawned exactly once, on the frame
    # that matters. Role-only and empty-content frames are protocol noise, not an
    # answer arriving, so they are skipped.
    SSE_T0=$(date +%s%3N)
    remote_exec "curl -sN --max-time 300 -H 'Authorization: Bearer $KEY' \
        -H 'Content-Type: application/json' -d $(_shq "$body") \
        http://127.0.0.1:$PORT/v1/chat/completions" 2>/dev/null \
    | {
        local line got=""
        while IFS= read -r line; do
            if [[ -z "$got" && "$line" == data:\ * ]]; then
                case "$line" in
                    *'"content":""'*) ;;   # empty delta, keep waiting
                    *'"content":"'*|*'"tool_calls"'*)
                        got=1; date +%s%3N > "$tf" ;;
                esac
            fi
            printf '%s\n' "$line"
        done
    } > "$out"

    SSE_TFIRST=$(cat "$tf" 2>/dev/null)
    SSE_FRAMES=$(grep -c '^data: ' "$out")
    SSE_FILE="$out"
}

# Pull the assembled result out of the captured stream.
parse_turn() {
    local frames
    frames=$(grep '^data: ' "$SSE_FILE" | sed 's/^data: //' | grep -v '^\[DONE\]$')
    # timings_per_token puts full server timings on every frame; the last is final.
    local t
    t=$(jq -c 'select(.timings) | .timings' <<<"$frames" 2>/dev/null | tail -1)
    R_CACHE_N=$(jq -r '.cache_n // 0' <<<"${t:-\{\}}" 2>/dev/null)
    R_PROMPT_N=$(jq -r '.prompt_n // 0' <<<"${t:-\{\}}" 2>/dev/null)
    R_PROMPT_MS=$(jq -r '.prompt_ms // 0' <<<"${t:-\{\}}" 2>/dev/null)
    R_GEN_TPS=$(jq -r '.predicted_per_second // 0' <<<"${t:-\{\}}" 2>/dev/null)
    R_ERROR=$(grep -oE '"message":"[^"]{0,140}' "$SSE_FILE" | head -1)
}

# ── One full session ──────────────────────────────────────────────────────────
# phase: cold  -> every turn gets a unique nonce so no prefix can be reused
#        warm  -> the fixture's exact prefix, so history accumulates and reuses
run_session() {
    local phase="$1" iter="$2" nonce="" i turn body msgs expect
    [[ "$phase" == "cold" ]] && nonce="[run $iter-$(date +%s%N)] "

    # History starts as the system message and grows with RECORDED turns only.
    msgs=$(jq -nc --arg s "$nonce$SYSTEM" '[{role:"system",content:$s}]')

    for ((i = 0; i < N_TURNS; i++)); do
        turn=$(jq -c ".turns[$i]" "$FIXTURE")
        expect=$(jq -r '.expect' <<<"$turn")

        msgs=$(jq -c --arg u "$(jq -r '.user' <<<"$turn")" \
                    '. + [{role:"user",content:$u}]' <<<"$msgs")

        local choice=null
        [[ "$TOOL_CHOICE" == "turn" ]] && choice=$( [[ "$expect" == "tool_call" ]] && echo '"required"' || echo '"none"')
        body=$(jq -nc --arg m "$BENCH_INSTANCE" --argjson msgs "$msgs" \
                      --argjson tools "$TOOLS" --argjson mt "$MAX_TOKENS" \
                      --argjson seed "$((SEED + iter))" --argjson extra "$EXTRA" \
                      --argjson choice "$choice" --arg sampler "$SAMPLER" \
                      --argjson temp "$TEMP" --argjson tp "$TOP_P" --argjson tk "$TOP_K" '{
            model: $m, messages: $msgs, tools: $tools,
            stream: true, timings_per_token: true,
            max_tokens: $mt, seed: $seed }
            + (if $sampler == "client" then {temperature: $temp, top_p: $tp, top_k: $tk} else {} end)
            + (if $choice then {tool_choice: $choice} else {} end)
            + $extra')

        stream_turn "$body"
        parse_turn
        n_turns+=1

        local id; id=$(jq -r '.id' <<<"$turn")
        printf '    %-22s ' "$id"

        # --- correctness ---
        if [[ -n "$R_ERROR" ]]; then
            n_http_bad+=1; echo -e "${RED}error${NC} $R_ERROR"; continue
        fi
        if ((SSE_FRAMES < 2)); then
            n_stream_bad+=1
            echo -e "${RED}buffered${NC} ($SSE_FRAMES frame) — streaming regressed"
            continue
        fi

        judge_turn "$turn" "$SSE_FILE"
        case "$VERDICT" in
            missing)              n_toolcall_missing+=1 ;;
            invalid_json)         n_toolargs_bad+=1 ;;
            schema)               n_schema_bad+=1 ;;
            wrong_tool)           n_wrong_tool+=1 ;;
            unexpected_call)      n_unexpected_call+=1 ;;
            no_content)           n_stream_bad+=1 ;;
            reasoning_ate_budget) n_reasoning_ate_budget+=1 ;;
        esac
        if [[ "$VERDICT" != ok ]]; then
            echo -e "${RED}FAIL $VERDICT${NC} $NOTE"
            continue
        fi
        local note="$NOTE"
        if [[ "$expect" == "tool_call" && "$R_FINISH" != "tool_calls" ]]; then
            n_finish_bad+=1; note="finish=$R_FINISH $note"
        fi

        # --- cache behaviour ---
        # Turn 1 of a cold session must genuinely be cold, and later turns of a
        # warm session must genuinely reuse. Both are asserted, not assumed.
        local total=$((R_CACHE_N + R_PROMPT_N)) ratio=0
        ((total > 0)) && ratio=$((R_CACHE_N * 100 / total))
        if [[ "$phase" == "cold" && $i -eq 0 ]]; then
            # Not `cache_n == 0`: the chat template's own preamble tokens always
            # match, so a genuinely cold turn still reports cache_n of 1-2. What
            # matters is that essentially the whole prompt was reprocessed.
            if ((ratio > 5)); then
                n_cold_not_cold+=1
                note+=" cold turn reused ${ratio}% of its prompt — the nonce failed"
            fi
        elif [[ "$phase" == "warm" && $i -gt 0 ]]; then
            if ((R_CACHE_N == 0)); then
                n_warm_not_warm+=1
                note+=" cache_n=0 — prompt caching is not working"
            fi
            HIT_RATIO+=("$ratio")
        fi

        # --- latency (advisory) ---
        if [[ -n "$SSE_TFIRST" ]]; then
            local ttft=$((SSE_TFIRST - SSE_T0))
            TTFT_MS+=("$ttft")
            # Everything outside the model's own prefill: ttft minus timings.prompt_ms.
            #
            # CAVEAT: this suite reaches the instance over SSH on the target's
            # loopback, so what this measures is ssh + bash pipeline overhead, NOT
            # the app's cloudflared -> nginx path. It is useful as a stable
            # "non-model time" reference between runs on this harness; do not quote
            # it to the app team as their proxy cost. Measuring that needs a client
            # sitting where the app sits.
            local proxy
            proxy=$(awk -v a="$ttft" -v b="$R_PROMPT_MS" 'BEGIN{printf "%d", a-b}')
            PROXY_MS+=("$proxy")
        fi
        PROMPT_MS+=("$R_PROMPT_MS")
        GEN_TPS+=("$R_GEN_TPS")

        printf 'ok  %sframes=%s cache=%s/%s %s\n' \
            "$( ((total>0)) && printf 'hit=%d%% ' "$ratio")" \
            "$SSE_FRAMES" "$R_CACHE_N" "$total" "$note"

        # Append the RECORDED turn, not the model's output — see header.
        local ra rt
        ra=$(jq -c '.replay_assistant' <<<"$turn")
        if ((REPLAY_REASONING)) && [[ -n "$R_REASONING" ]]; then
            ra=$(jq -c --arg r "$R_REASONING" '. + {reasoning_content: $r}' <<<"$ra")
        fi
        msgs=$(jq -c --argjson a "$ra" '. + [$a]' <<<"$msgs")
        rt=$(jq -c '.replay_tool // empty' <<<"$turn")
        [[ -n "$rt" && "$rt" != "null" ]] && msgs=$(jq -c --argjson t "$rt" '. + ($t | if type == "array" then . else [.] end)' <<<"$msgs")
    done
}

# ── Stats ─────────────────────────────────────────────────────────────────────
_stat() {
    local what="$1"; shift
    (($# == 0)) && { echo "null"; return; }
    printf '%s\n' "$@" | sort -g | awk -v what="$what" '
        {v[NR]=$1}
        END{
            if (NR==0) {print "null"; exit}
            if (what=="med")  {print (NR%2 ? v[(NR+1)/2] : (v[NR/2]+v[NR/2+1])/2); exit}
            if (what=="p95")  {i=int(0.95*NR); if(i<1)i=1; print v[i]; exit}
            if (what=="min")  {print v[1]; exit}
            if (what=="max")  {print v[NR]; exit}
            s=0; for(i=1;i<=NR;i++) s+=v[i]; printf "%.4f", s/NR
        }'
}

# ── Run ───────────────────────────────────────────────────────────────────────
echo -e "${BLUE}Agent workload benchmark${NC}"
echo -e "  instance:  $BENCH_INSTANCE (:$PORT, $INST_CONTEXT_PER_REQUEST tok/req x $INST_PARALLEL_SLOTS slots)"
echo -e "  fixture:   $FIXTURE ($N_TURNS turns)"
echo -e "  iterations: $ITERATIONS x (cold + warm)"
echo -e "  request:   extra=$EXTRA sampler=$SAMPLER tool_choice=$TOOL_CHOICE replay_reasoning=$REPLAY_REASONING"
echo ""

for ((it = 1; it <= ITERATIONS; it++)); do
    echo -e "  ${CYAN}iteration $it — cold${NC} (unique prefix, no cache reuse possible)"
    run_session cold "$it"
    echo -e "  ${CYAN}iteration $it — warm${NC} (fixture prefix, history accumulates)"
    run_session warm "$it"
done

# ── Report ────────────────────────────────────────────────────────────────────
mkdir -p "$OUT_DIR"
RESULT="$OUT_DIR/$LABEL.json"

jq -n \
  --arg label "$LABEL" \
  --arg instance "$BENCH_INSTANCE" \
  --arg fixture "$FIXTURE" \
  --argjson env "$(jq -nc \
        --argjson cpr "$INST_CONTEXT_PER_REQUEST" \
        --argjson slots "$INST_PARALLEL_SLOTS" \
        --argjson total "$INST_TOTAL_CONTEXT" \
        --arg ctk "$INST_CACHE_TYPE_K" --arg ctv "$INST_CACHE_TYPE_V" \
        --arg build "$(remote_exec "curl -sf -H 'Authorization: Bearer $KEY' http://127.0.0.1:$PORT/props" 2>/dev/null | jq -r '.build_info // "unknown"')" \
        --argjson extra "$EXTRA" --arg sampler "$SAMPLER" --arg choice "$TOOL_CHOICE" \
        --argjson replay "$REPLAY_REASONING" \
        '{contextPerRequest:$cpr, parallelSlots:$slots, totalContext:$total,
          cacheTypeK:$ctk, cacheTypeV:$ctv, build:$build, extra:$extra,
          sampler:$sampler, toolChoice:$choice, replayReasoning:($replay==1)}')" \
  --argjson correctness "$(jq -nc \
        --argjson turns "$n_turns" --argjson http "$n_http_bad" \
        --argjson stream "$n_stream_bad" --argjson missing "$n_toolcall_missing" \
        --argjson args "$n_toolargs_bad" --argjson schema "$n_schema_bad" \
        --argjson finish "$n_finish_bad" --argjson cold "$n_cold_not_cold" \
        --argjson warm "$n_warm_not_warm" \
        --argjson reason "$n_reasoning_ate_budget" \
        --argjson wrong "$n_wrong_tool" --argjson unexpected "$n_unexpected_call" \
        '{turns:$turns, httpErrors:$http, streamingBroken:$stream,
          toolCallMissing:$missing, wrongToolName:$wrong, unexpectedToolCall:$unexpected,
          toolArgsInvalidJson:$args,
          toolArgsSchemaMismatch:$schema, finishReasonWrong:$finish,
          coldTurnWasCached:$cold, warmTurnNotCached:$warm,
          budgetExhaustedByReasoning:$reason}')" \
  --argjson latency "$(jq -nc \
        --arg tm "$(_stat med "${TTFT_MS[@]}")"   --arg tp "$(_stat p95 "${TTFT_MS[@]}")" \
        --arg pm "$(_stat med "${PROMPT_MS[@]}")" --arg gm "$(_stat med "${GEN_TPS[@]}")" \
        --arg hm "$(_stat med "${HIT_RATIO[@]}")" --arg xm "$(_stat med "${PROXY_MS[@]}")" \
        '{ttftMsMedian:($tm|tonumber?), ttftMsP95:($tp|tonumber?),
          serverPromptMsMedian:($pm|tonumber?), genTokensPerSecMedian:($gm|tonumber?),
          warmCacheHitPctMedian:($hm|tonumber?), harnessOverheadMsMedian:($xm|tonumber?)}')" \
  '{schema:1, label:$label, instance:$instance, fixture:$fixture,
    env:$env, correctness:$correctness, latency:$latency}' > "$RESULT"

echo ""
echo -e "${YELLOW}correctness${NC} (these gate)"
jq -r '.correctness | to_entries[] | "  \(.key): \(.value)"' "$RESULT"
echo -e "${YELLOW}latency${NC} (advisory)"
jq -r '.latency | to_entries[] | "  \(.key): \(.value)"' "$RESULT"
echo ""
echo -e "wrote ${BLUE}$RESULT${NC}"

if ((ACCEPT)); then
    cp "$RESULT" "$BASELINE"
    echo -e "${GREEN}baseline updated${NC} -> $BASELINE (commit it to record the trade)"
fi

# ── Gate ──────────────────────────────────────────────────────────────────────
# Every correctness counter must be zero. No tolerance band: these are binary
# properties, so a nonzero value is a real regression, never noise.
agent_gate "$RESULT" $((N_TURNS * ITERATIONS * 2)) || exit 1

# Warm turns must actually reuse the cache, or the multi-turn story is broken
# even though every turn "worked".
HIT=$(_stat med "${HIT_RATIO[@]}")
if [[ "$HIT" != "null" ]] && awk -v h="$HIT" 'BEGIN{exit !(h < 50)}'; then
    echo -e "${RED}FAIL${NC} warm cache hit ratio median ${HIT}% — prompt reuse has regressed"
    exit 1
fi

echo -e "${GREEN}PASS${NC} $n_turns turns, no correctness regressions (warm cache hit median ${HIT}%)"

if [[ -f "$BASELINE" ]]; then
    echo ""
    echo -e "${YELLOW}vs baseline${NC} (advisory)"
    jq -rn --slurpfile b "$BASELINE" --slurpfile c "$RESULT" '
        ($b[0].latency) as $bl | ($c[0].latency) as $cl |
        ($bl | keys_unsorted[]) as $k |
        "  \($k): \($bl[$k]) -> \($cl[$k])"' 2>/dev/null || true
fi
