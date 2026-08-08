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
    cmdline=$(remote_exec "tr '\\0' ' ' < /proc/\$(pgrep -f -- '--alias $name ' | head -1)/cmdline 2>/dev/null" || echo "")
    if [[ -z "$cmdline" ]]; then
        bad "could not read the live cmdline"
    else
        assert_eq "live -c"  "$(grep -oP '(?:^|\s)-c\s+\K[0-9]+' <<<"$cmdline" | head -1)"  "$INST_TOTAL_CONTEXT"
        assert_eq "live -np" "$(grep -oP '(?:^|\s)-np\s+\K[0-9]+' <<<"$cmdline" | head -1)" "$INST_PARALLEL_SLOTS"
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
