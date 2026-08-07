#!/bin/bash
# Test the effective PER-REQUEST context window.
# llama.cpp divides --ctx-size across --parallel slots unless --kv-unified,
# so what a client gets is n_ctx_seq, not the configured total.
#
# Usage: ./tests/test-context-window.sh [test-name]
#   ONE TEST AT A TIME: ./tests/test-context-window.sh test_effective_context_meets_floor
#   ALL TESTS:          ./tests/test-context-window.sh
#   OTHER TARGET:       LLM_HOST=... LLAMA_API_KEY=... ./tests/test-context-window.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

# Explicit env wins over .env
_env_host="${LLM_HOST:-}"
_env_key="${LLAMA_API_KEY:-}"
source .env 2>/dev/null || true
[[ -n "$_env_host" ]] && LLM_HOST="$_env_host"
[[ -n "$_env_key" ]] && LLAMA_API_KEY="$_env_key"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

HOST="${LLM_HOST:-}"
if [[ -z "$HOST" ]]; then
    echo -e "${RED}FAIL${NC}: LLM_HOST not set in .env"
    exit 1
fi

ENDPOINT="https://$HOST"
API_KEY="${LLAMA_API_KEY:-}"
MODEL="${LLM_MODEL:-qwen3-14b}"

# CONTEXT_SIZE_ISSUE.md asks for >= 8192; we target 16384 for headroom
MIN_CONTEXT="${MIN_CONTEXT:-16384}"
# twofit agent/base/providers.py:7
CLIENT_MAX_OUTPUT="${CLIENT_MAX_OUTPUT:-4096}"

AUTH_HEADER=()
[[ -n "$API_KEY" ]] && AUTH_HEADER=(-H "Authorization: Bearer $API_KEY")

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

PASSED=0
FAILED=0
HTTP_CODE=""
pass() { echo -e "${GREEN}PASS${NC}: $*"; PASSED=$((PASSED + 1)); }
fail() { echo -e "${RED}FAIL${NC}: $*"; FAILED=$((FAILED + 1)); }

# ~11 tokens per repetition. Written via the printf builtin, not passed as an
# argument — a 270KB string blows past ARG_MAX.
filler() {
    local reps="$1"
    local out=""
    local i
    for ((i = 0; i < reps; i++)); do
        out+="the quick brown fox jumps over the lazy dog. "
    done
    printf '%s' "$out"
}

write_prompt() {
    local out="$1" prefix="$2" reps="$3" suffix="${4:-}"
    {
        [[ -n "$prefix" ]] && printf '%s\n\n' "$prefix"
        filler "$reps"
        [[ -n "$suffix" ]] && printf '\n\n%s' "$suffix"
    } > "$out"
}

# Sets $HTTP_CODE, writes body to $RESP_BODY. Must not be called via $(...),
# which would discard the HTTP_CODE assignment in a subshell.
RESP_BODY=""
post_json() {
    local file="$1" timeout="${2:-120}"
    RESP_BODY="$TMPDIR_TEST/response.json"
    HTTP_CODE=$(curl -s --max-time "$timeout" \
        -o "$RESP_BODY" -w '%{http_code}' \
        "$ENDPOINT/v1/chat/completions" \
        -H "Content-Type: application/json" \
        ${AUTH_HEADER[@]+"${AUTH_HEADER[@]}"} \
        --data-binary "@$file") || HTTP_CODE="000"
}

# ── TEST 1 ────────────────────────────────────────────────────────────────────
# Overflow on purpose and read n_ctx out of the error body. Works through the
# nginx allowlist, which 404s /props and /slots.
test_effective_context_meets_floor() {
    echo "TEST: effective per-request context >= $MIN_CONTEXT tokens"

    write_prompt "$TMPDIR_TEST/overflow.txt" "" 6000
    jq -n --arg m "$MODEL" --rawfile c "$TMPDIR_TEST/overflow.txt" \
        '{model:$m, messages:[{role:"user",content:$c}], max_tokens:8}' \
        > "$TMPDIR_TEST/overflow.json"

    local result n_ctx
    post_json "$TMPDIR_TEST/overflow.json" 120
    result=$(cat "$RESP_BODY")

    n_ctx=$(echo "$result" | jq -r '.error.n_ctx // empty' 2>/dev/null)

    if [[ -z "$n_ctx" ]]; then
        if [[ "$HTTP_CODE" == "200" ]]; then
            pass "server accepted a ~66k-token prompt; window exceeds $MIN_CONTEXT"
            return
        fi
        fail "could not read .error.n_ctx (HTTP $HTTP_CODE)"
        echo "$result" | head -c 400
        echo
        return
    fi

    echo "  server reports n_ctx = $n_ctx (per slot)"
    if ((n_ctx < MIN_CONTEXT)); then
        fail "effective context $n_ctx < required $MIN_CONTEXT"
        echo -e "  ${YELLOW}Fix: raise context_per_request or lower parallel_slots.${NC}"
        echo -e "  ${YELLOW}Remember -c is a TOTAL that gets divided by -np.${NC}"
    else
        pass "effective context $n_ctx >= $MIN_CONTEXT"
    fi
}

# ── TEST 2 ────────────────────────────────────────────────────────────────────
test_long_prompt_completes() {
    echo "TEST: a ~6k-token prompt completes without overflow"

    write_prompt "$TMPDIR_TEST/long.txt" "Summarize the following text in one sentence." 550
    jq -n --arg m "$MODEL" --rawfile c "$TMPDIR_TEST/long.txt" \
        '{model:$m, messages:[{role:"user",content:$c}], max_tokens:256}' \
        > "$TMPDIR_TEST/long.json"

    local result content
    post_json "$TMPDIR_TEST/long.json" 180
    result=$(cat "$RESP_BODY")

    if [[ "$HTTP_CODE" != "200" ]]; then
        fail "HTTP $HTTP_CODE on a ~6k-token prompt"
        echo "$result" | jq -c '.error // .' 2>/dev/null | head -c 300
        echo
        return
    fi

    content=$(echo "$result" | jq -r '.choices[0].message.content // ""' 2>/dev/null)
    if [[ -z "$content" ]]; then
        fail "HTTP 200 but empty content on a ~6k-token prompt"
        echo "$result" | jq -c '{finish_reason:.choices[0].finish_reason, usage}' 2>/dev/null
        return
    fi
    pass "~6k-token prompt returned $(printf '%s' "$content" | wc -c) chars"
}

# ── TEST 3 ────────────────────────────────────────────────────────────────────
# A tool turn is the biggest shape the client sends: schema + call + result.
# This asserts it FITS. Whether tool-calling itself behaves correctly is a
# separate concern and is not tested here.
test_tool_shaped_turn_fits() {
    echo "TEST: a tool-shaped turn fits in the window"

    write_prompt "$TMPDIR_TEST/toolresult.txt" \
        "Search results for 'gym membership promotion best practices':" 130

    jq -n --arg m "$MODEL" --argjson maxtok "$CLIENT_MAX_OUTPUT" \
        --rawfile toolresult "$TMPDIR_TEST/toolresult.txt" '{
      model: $m,
      max_tokens: $maxtok,
      messages: [
        {role:"system", content:"You are a marketing agent for a fitness company. You have access to tools and must use them when current information would help. Follow these rules strictly: always ground claims in retrieved data; never invent statistics; keep copy under 60 words; match an energetic but professional tone; avoid superlatives you cannot support. When you have finished researching, reply with ONLY a JSON object matching this schema: {\"headline\": string, \"body\": string, \"call_to_action\": string}. Do not wrap the JSON in markdown fences. Do not add commentary before or after the JSON."},
        {role:"user", content:"Draft a promotional message for our new gym membership offer. Research current best practices first."},
        {role:"assistant", content:"", tool_calls:[{
          id:"call_1", type:"function",
          function:{name:"web_search", arguments:"{\"query\":\"gym membership promotion best practices\"}"}
        }]},
        {role:"tool", tool_call_id:"call_1", content:$toolresult}
      ],
      tools: [{
        type: "function",
        function: {
          name: "web_search",
          description: "Search the web for current information on any topic. Returns a list of relevant excerpts.",
          parameters: {
            type: "object",
            properties: {
              query: { type: "string", description: "The search query" },
              max_results: { type: "integer", description: "How many results to return" }
            },
            required: ["query"]
          }
        }
      }]
    }' > "$TMPDIR_TEST/tools.json"

    local result finish used
    post_json "$TMPDIR_TEST/tools.json" 240
    result=$(cat "$RESP_BODY")

    if [[ "$HTTP_CODE" == "400" ]]; then
        fail "tool-shaped turn rejected: $(echo "$result" | jq -r '.error.message // ""')"
        return
    fi
    if [[ "$HTTP_CODE" != "200" ]]; then
        fail "HTTP $HTTP_CODE on a tool-shaped turn"
        echo "$result" | jq -c '.error // .' 2>/dev/null | head -c 300
        echo
        return
    fi

    finish=$(echo "$result" | jq -r '.choices[0].finish_reason // ""' 2>/dev/null)
    used=$(echo "$result" | jq -r '.usage.total_tokens // 0' 2>/dev/null)

    if [[ "$finish" == "length" ]]; then
        fail "tool-shaped turn truncated at $used tokens (finish_reason=length)"
        return
    fi
    pass "tool-shaped turn fit in $used tokens (finish_reason=$finish)"
}

# ── TEST 4 ────────────────────────────────────────────────────────────────────
# --no-context-shift is the default since Aug 2025, so overflowing mid-generation
# returns HTTP 200 + finish_reason=length, indistinguishable from hitting max_tokens.
test_no_silent_truncation() {
    echo "TEST: a realistic agent turn is not silently truncated"

    write_prompt "$TMPDIR_TEST/truncate.txt" \
        "You are an assistant. Think carefully, then answer." 180 \
        "Based on the text above, explain in detail what a pangram is and why this one is used."
    jq -n --arg m "$MODEL" --argjson maxtok "$CLIENT_MAX_OUTPUT" \
        --rawfile c "$TMPDIR_TEST/truncate.txt" \
        '{model:$m, messages:[{role:"user",content:$c}], max_tokens:$maxtok}' \
        > "$TMPDIR_TEST/truncate.json"

    local result finish content
    post_json "$TMPDIR_TEST/truncate.json" 300
    result=$(cat "$RESP_BODY")

    if [[ "$HTTP_CODE" != "200" ]]; then
        fail "HTTP $HTTP_CODE on a realistic agent turn"
        echo "$result" | jq -c '.error // .' 2>/dev/null | head -c 300
        echo
        return
    fi

    finish=$(echo "$result" | jq -r '.choices[0].finish_reason // ""' 2>/dev/null)
    content=$(echo "$result" | jq -r '.choices[0].message.content // ""' 2>/dev/null)

    if [[ "$finish" == "length" ]]; then
        fail "finish_reason=length — output budget exhausted or window hit"
        echo "$result" | jq -c '.usage' 2>/dev/null
        return
    fi
    if [[ -z "$content" ]]; then
        fail "HTTP 200 with empty content (finish_reason=$finish)"
        echo "$result" | jq -c '.usage' 2>/dev/null
        return
    fi
    pass "agent turn completed cleanly (finish_reason=$finish)"
}

# ── TEST 5 ────────────────────────────────────────────────────────────────────
# Arithmetic only, no network
test_output_budget_fits_window() {
    echo "TEST: client max_output_tokens ($CLIENT_MAX_OUTPUT) fits in $MIN_CONTEXT"

    local typical_prompt=4000 required
    required=$((typical_prompt + CLIENT_MAX_OUTPUT))

    if ((MIN_CONTEXT < required)); then
        fail "window $MIN_CONTEXT < prompt ($typical_prompt) + output ($CLIENT_MAX_OUTPUT) = $required"
        return
    fi
    pass "window $MIN_CONTEXT leaves $((MIN_CONTEXT - required)) tokens of headroom"
}

# ── RUNNER ────────────────────────────────────────────────────────────────────
echo -e "${BLUE}Testing effective context window${NC}"
echo -e "  endpoint: $ENDPOINT"
echo -e "  model:    $MODEL"
echo -e "  required: $MIN_CONTEXT tokens per request"
echo ""

if [[ $# -ge 1 ]]; then
    "$1"
else
    test_effective_context_meets_floor
    echo ""
    test_long_prompt_completes
    echo ""
    test_tool_shaped_turn_fits
    echo ""
    test_no_silent_truncation
    echo ""
    test_output_budget_fits_window
    echo ""
fi

echo "─────────────────────────────────────────"
echo -e "${GREEN}$PASSED passed${NC}, ${RED}$FAILED failed${NC}"
[[ "$FAILED" -eq 0 ]]
