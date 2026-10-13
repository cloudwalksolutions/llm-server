# Judge one streamed chat turn against what its fixture turn expects.
#
# judge_turn <turn-json> <sse-file>
# Sets R_CONTENT, R_REASONING, R_CALLS (a JSON array of {name, args}), R_FINISH,
# then VERDICT: ok | missing | invalid_json | wrong_tool | schema |
#               unexpected_call | no_content | reasoning_ate_budget
# and NOTE, a one-line explanation.
judge_turn() {
    local turn="$1" sse="$2" frames
    frames=$(grep '^data: ' "$sse" | sed 's/^data: //' | grep -v '^\[DONE\]$')
    R_CONTENT=$(jq -rj '.choices[0].delta.content // empty' <<<"$frames" 2>/dev/null)
    R_REASONING=$(jq -rj '.choices[0].delta.reasoning_content // empty' <<<"$frames" 2>/dev/null)
    R_CALLS=$(jq -sc '[.[] | .choices[0].delta.tool_calls[]?] | group_by(.index)
        | map({name: (map(.function.name // "") | join("")),
               args: (map(.function.arguments // "") | join(""))})' <<<"$frames" 2>/dev/null)
    R_CALLS=${R_CALLS:-[]}
    R_FINISH=$(jq -r 'select(.choices[0].finish_reason != null) | .choices[0].finish_reason' <<<"$frames" 2>/dev/null | head -1)

    local n_calls want_tools got_tools k missing=""
    n_calls=$(jq 'length' <<<"$R_CALLS")
    NOTE=""

    if [[ "$R_FINISH" == "length" && -n "$R_REASONING" && -z "$R_CONTENT" ]] && ((n_calls == 0)); then
        VERDICT=reasoning_ate_budget
        NOTE="${#R_REASONING} chars of reasoning, no answer, finish=length"
        return
    fi

    if [[ "$(jq -r '.expect' <<<"$turn")" != "tool_call" ]]; then
        if ((n_calls > 0)); then
            VERDICT=unexpected_call; NOTE="called $(jq -r 'map(.name) | join(",")' <<<"$R_CALLS")"
        elif [[ -z "$R_CONTENT" ]]; then
            VERDICT=no_content; NOTE="finish=$R_FINISH"
        else
            VERDICT=ok; NOTE="${#R_CONTENT} chars"
        fi
        return
    fi

    if ((n_calls == 0)); then
        VERDICT=missing
        NOTE="finish=$R_FINISH content=[$(tr '\n' ' ' <<<"${R_CONTENT:0:160}")]"
        return
    fi
    if ! jq -e 'all(.args | fromjson? | type == "object")' <<<"$R_CALLS" >/dev/null 2>&1; then
        VERDICT=invalid_json; NOTE="args=$(jq -c 'map(.args)' <<<"$R_CALLS")"
        return
    fi
    want_tools=$(jq -c '.tools // [] | sort' <<<"$turn")
    got_tools=$(jq -c 'map(.name) | sort' <<<"$R_CALLS")
    if [[ "$want_tools" != "[]" ]] && ! jq -e --argjson w "$want_tools" 'all(IN($w[]))' <<<"$got_tools" >/dev/null; then
        VERDICT=wrong_tool; NOTE="want $want_tools, got $got_tools"
        return
    fi
    while read -r k; do
        jq -e --arg k "$k" '.[0].args | fromjson | has($k)' <<<"$R_CALLS" >/dev/null 2>&1 || missing+=" $k"
    done < <(jq -r '.required_args[]?' <<<"$turn")
    if [[ -n "$missing" ]]; then
        VERDICT=schema; NOTE="args missing:$missing"
        return
    fi
    VERDICT=ok; NOTE="$(jq -c 'map("\(.name) \(.args)")' <<<"$R_CALLS")"
}
