#!/usr/bin/env bash

now_ms() {
    local us="${EPOCHREALTIME/[.,]/}"
    echo $((us / 1000))
}

# Pass an agent benchmark result only if every planned turn ran and every
# correctness counter is zero. A harness that dies mid-run counts few turns
# and no errors, which must not read as a pass.
agent_gate() {
    local result="$1" planned="$2" fails turns
    fails=$(jq -r '[.correctness | to_entries[] | select(.key != "turns" and .value != 0)]
                   | map("\(.key)=\(.value)") | join(" ")' "$result")
    if [[ -n "$fails" ]]; then
        echo -e "${RED}FAIL${NC} $fails"
        return 1
    fi
    turns=$(jq -r '.correctness.turns // 0' "$result" 2>/dev/null)
    turns=${turns:-0}
    if ((turns != planned || planned == 0)); then
        echo -e "${RED}FAIL${NC} $turns of $planned turns ran"
        return 1
    fi
}
