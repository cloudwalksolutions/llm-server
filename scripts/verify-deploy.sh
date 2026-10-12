#!/usr/bin/env bash
# Assert the RUNNING instances match config/llama.yaml.
#
# Compares three sources per instance: yaml intent -> the target's instance
# conf -> the live process and its reported window. Drift between any two is
# what made the context bug hard to find.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

load_config "${LLAMA_CONFIG:-config/llama.yaml}" || exit 1

PASSED=0
FAILED=0
ok()  { echo -e "  ${GREEN}PASS${NC} $*"; PASSED=$((PASSED + 1)); }
bad() { echo -e "  ${RED}FAIL${NC} $*"; FAILED=$((FAILED + 1)); }

assert_eq() {
    local label="$1" got="$2" want="$3"
    [[ "$got" == "$want" ]] && ok "$label = $got" || bad "$label: want '$want', got '$got'"
}

# Does a streamed tool call actually work end to end?
#
# This is the only assertion here that tests a capability rather than a value,
# and it is the one the consuming app depends on. It deliberately checks
# behaviour instead of flags, because the flags are not the contract and have
# already moved once:
#   - jinja is a default rather than a flag since llama.cpp b7170, so grepping
#     the cmdline for --jinja would fail on a server that works perfectly
#   - it can still be turned off out of band, by --no-jinja, by the synthesized
#     LLAMA_ARG_NO_JINJA env var (which triggers on presence, not value), by
#     --skip-chat-parsing, or by rolling the container image back below b7170
#   - /props reports chat_template_caps.supports_tools: false on this build
#     while tool calls demonstrably work, so that field is not usable either
# Reassembling the streamed argument deltas also catches the live class of
# upstream bugs where a partial fragment like `{` is flushed before a 500.
assert_streamed_tool_call() {
    local name="$1" port="$2" key="$3" extra="${4:-{\}}" label="${5:-streamed tool call}" body out args fr
    body=$(jq -nc --arg m "$name" --argjson mt "$((INST_REASONING_BUDGET + 256))" --argjson extra "$extra" '{
        model: $m, stream: true, max_tokens: $mt, tool_choice: "required",
        messages: [{role: "user", content: "What is the weather in Paris?"}],
        tools: [{type: "function", function: {
            name: "get_weather",
            description: "Get the current weather for a city",
            parameters: {type: "object",
                         properties: {city: {type: "string"}},
                         required: ["city"]}}}]} + $extra')

    out=$(remote_exec "curl -s --max-time 120 -H 'Authorization: Bearer $key' \
        -H 'Content-Type: application/json' -d $(_shq "$body") \
        http://127.0.0.1:$port/v1/chat/completions" 2>/dev/null || echo "")

    if [[ -z "$out" ]]; then
        bad "streamed tool call: no response from 127.0.0.1:$port"
        return
    fi
    # Errors come back as a JSON object, not an SSE stream.
    if grep -qE '"error"|requires --jinja|Failed to parse input' <<<"$out"; then
        bad "streamed tool call rejected: $(grep -oE '"message":"[^"]{0,120}' <<<"$out" | head -1)"
        return
    fi

    local frames
    frames=$(grep '^data: ' <<<"$out" | sed 's/^data: //' | grep -v '^\[DONE\]$')
    args=$(jq -rj '.choices[0].delta.tool_calls[0].function.arguments // empty' <<<"$frames" 2>/dev/null)
    fr=$(jq -r 'select(.choices[0].finish_reason != null) | .choices[0].finish_reason' <<<"$frames" 2>/dev/null | head -1)

    if [[ -z "$args" ]]; then
        bad "$label produced no tool_calls arguments (finish_reason=${fr:-none})"
        return
    fi
    if ! jq -e 'has("city")' <<<"$args" >/dev/null 2>&1; then
        bad "streamed tool args are not valid JSON with the required key: [$args]"
        return
    fi
    assert_eq "$label finish_reason" "$fr" "tool_calls"
    ok "$label args parse as JSON: $args"

    # More than one SSE frame is what "the answer arrives in more than one
    # piece" means from the app side; a single frame means buffering.
    local n
    n=$(grep -c '^data: ' <<<"$out")
    if ((n < 2)); then
        bad "response arrived in $n frame(s) — streaming has regressed to buffering"
    else
        ok "streamed in $n frames"
    fi
}

echo -e "${BLUE}Verifying $REMOTE_USER@$REMOTE_HOST${NC}\n"
test_ssh || { echo -e "${RED}Cannot reach target${NC}" >&2; exit 1; }

for name in "${INSTANCE_NAMES[@]}"; do
    load_instance "$name" || { echo -e "${RED}bad config for $name${NC}"; FAILED=$((FAILED + 1)); continue; }
    echo -e "${YELLOW}$name${NC} (port $INST_PORT)"

    unit="llama-server@$name"
    assert_eq "systemd active" "$(remote_exec "systemctl is-active $unit" 2>/dev/null)" "active"

    conf="$INSTANCES_DIR/$name.conf"
    assert_eq "conf CONTEXT_SIZE"   "$(remote_conf_value "$conf" CONTEXT_SIZE)"   "$INST_TOTAL_CONTEXT"
    assert_eq "conf PARALLEL_SLOTS" "$(remote_conf_value "$conf" PARALLEL_SLOTS)" "$INST_PARALLEL_SLOTS"
    assert_eq "conf CACHE_TYPE_K"   "$(remote_conf_value "$conf" CACHE_TYPE_K)"   "$INST_CACHE_TYPE_K"
    assert_eq "conf MODEL_FILE"     "$(remote_conf_value "$conf" MODEL_FILE)"     "$INST_MODEL_FILE"

    # The running process, not just the file on disk.
    #
    # MainPID rather than `pgrep -f -- '--alias NAME ' | head -1`: two processes
    # match that pattern (the podman client and the containerized server) and
    # head -1 picked whichever had the lower PID. MainPID is the unit's own
    # process — the podman client — whose argv carries the full flag list.
    pid=$(remote_exec "systemctl show -p MainPID --value $unit" 2>/dev/null | tr -d '\r')
    if [[ ! "$pid" =~ ^[0-9]+$ ]] || ((pid == 0)); then
        bad "no MainPID for $unit"
        cmdline=""
    else
        cmdline=$(remote_exec "tr '\\0' ' ' < /proc/$pid/cmdline 2>/dev/null" || echo "")
    fi
    if [[ -z "$cmdline" ]]; then
        bad "could not read the live cmdline"
    else
        assert_eq "live -c"  "$(grep -oP '(?:^|\s)-c\s+\K[0-9]+' <<<"$cmdline" | head -1)"  "$INST_TOTAL_CONTEXT"
        assert_eq "live -np" "$(grep -oP '(?:^|\s)-np\s+\K[0-9]+' <<<"$cmdline" | head -1)" "$INST_PARALLEL_SLOTS"
        assert_eq "live --reasoning-budget" "$(grep -oP '(?:^|\s)--reasoning-budget\s+\K[0-9]+' <<<"$cmdline" | head -1)" "$INST_REASONING_BUDGET"
        if grep -qF -- "--reasoning-budget-message $INST_REASONING_BUDGET_MESSAGE" <<<"$cmdline"; then
            ok "live --reasoning-budget-message"
        else
            bad "live --reasoning-budget-message is not '$INST_REASONING_BUDGET_MESSAGE'"
        fi
    fi

    # What a client actually gets. Read on the target's loopback port, so this
    # works regardless of what the reverse proxy exposes.
    key=$(remote_conf_value "$conf" LLAMA_API_KEY)
    slot_ctx=$(remote_exec "curl -sf -H 'Authorization: Bearer $key' http://127.0.0.1:$INST_PORT/props" 2>/dev/null \
        | jq -r '.default_generation_settings.n_ctx // empty' 2>/dev/null || echo "")
    if [[ -n "$slot_ctx" ]]; then
        assert_eq "effective n_ctx/request" "$slot_ctx" "$INST_CONTEXT_PER_REQUEST"
    else
        bad "could not read /props on 127.0.0.1:$INST_PORT"
    fi

    # /props reports one number for the whole server. /slots reports what each
    # slot actually got, so it catches a divergence /props would average away,
    # and proves the slot COUNT too — which nothing else here checks.
    slots=$(remote_exec "curl -sf -H 'Authorization: Bearer $key' http://127.0.0.1:$INST_PORT/slots" 2>/dev/null || echo "")
    if [[ -z "$slots" ]] || ! jq -e 'type == "array"' <<<"$slots" >/dev/null 2>&1; then
        bad "could not read /slots on 127.0.0.1:$INST_PORT"
    else
        assert_eq "slot count" "$(jq -r 'length' <<<"$slots")" "$INST_PARALLEL_SLOTS"
        # unique so a single mismatched slot cannot hide behind seven correct ones
        assert_eq "every slot n_ctx" \
            "$(jq -r '[.[].n_ctx] | unique | join(",")' <<<"$slots")" \
            "$INST_CONTEXT_PER_REQUEST"
    fi

    assert_streamed_tool_call "$name" "$INST_PORT" "$key"
    assert_streamed_tool_call "$name" "$INST_PORT" "$key" \
        '{"reasoning_budget_tokens": 0, "max_tokens": 64}' "tool call with a per-request budget of 0"
    echo ""
done

# nginx routes by this map; a mismatch means requests never reach the instance.
echo -e "${YELLOW}router${NC}"
router=$(remote_exec "cat $ROUTER_MAP 2>/dev/null" || echo "")
for name in "${INSTANCE_NAMES[@]}"; do
    load_instance "$name" || continue
    assert_eq "$name -> backend" \
        "$(jq -r --arg n "$name" '.[$n] // "missing"' <<<"$router" 2>/dev/null || echo missing)" \
        "127.0.0.1:$INST_PORT"
done

echo ""
echo "─────────────────────────────────────────"
echo -e "${GREEN}$PASSED passed${NC}, ${RED}$FAILED failed${NC}"
[[ "$FAILED" -eq 0 ]]
