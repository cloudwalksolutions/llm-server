#!/usr/bin/env bash
# Offline: judge_turn against hand-built SSE streams.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib/agent-judge.sh

PASSED=0 FAILED=0
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

frame()   { printf 'data: %s\n' "$1"; }
content() { frame "$(jq -nc --arg c "$1" '{choices:[{delta:{content:$c}}]}')"; }
call()    { frame "$(jq -nc --argjson i "$1" --arg n "$2" --arg a "$3" \
                '{choices:[{delta:{tool_calls:[{index:$i,function:{name:$n,arguments:$a}}]}}]}')"; }
finish()  { frame "{\"choices\":[{\"delta\":{},\"finish_reason\":\"$1\"}]}"; }

expect_verdict() {
    local name="$1" want="$2" turn="$3" sse="$WORK/s"
    cat > "$sse"
    judge_turn "$turn" "$sse"
    if [[ "$VERDICT" == "$want" ]]; then
        PASSED=$((PASSED + 1)); echo "PASS: $name"
    else
        FAILED=$((FAILED + 1)); echo "FAIL: $name — want $want, got $VERDICT ($NOTE)"
    fi
}

lookup='{"expect":"tool_call","tools":["get_customers"],"required_args":["query"]}'
resolve='{"expect":"tool_call","tools":["get_customers","get_users"]}'
answer='{"expect":"content"}'

expect_verdict "the expected tool with its required args passes" ok "$lookup" \
    < <(call 0 get_customers '{"query":'; call 0 "" '"acme"}'; finish tool_calls)

expect_verdict "an answer where a tool was needed is a missing call" missing "$lookup" \
    < <(content "Acme is a customer."; finish stop)

expect_verdict "calling a different tool is the wrong tool" wrong_tool "$lookup" \
    < <(call 0 get_users '{"query":"acme"}'; finish tool_calls)

expect_verdict "a call without a required arg fails the schema" schema "$lookup" \
    < <(call 0 get_customers '{"id":1}'; finish tool_calls)

expect_verdict "a turn needing two tools passes when both are called" ok "$resolve" \
    < <(call 0 get_customers '{"q":"a"}'; call 1 get_users '{"q":"a"}'; finish tool_calls)

expect_verdict "a tool call on a turn that needed an answer is unexpected" unexpected_call "$answer" \
    < <(call 0 get_customers '{"query":"acme"}'; finish tool_calls)

expect_verdict "an answer on an answer turn passes" ok "$answer" \
    < <(content "Here is the summary."; finish stop)

echo ""
echo "$PASSED passed, $FAILED failed"
((FAILED == 0))
