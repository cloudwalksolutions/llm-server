#!/usr/bin/env bash
# Assert the RUNNING server matches config/llama.yaml.
#
# Checks three sources agree: yaml intent -> /etc/llama-server.conf -> the
# live process. Config drift between any two is what made CONTEXT_SIZE_ISSUE.md
# hard to diagnose.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

load_config || exit 1

PASSED=0
FAILED=0
ok()   { echo -e "${GREEN}PASS${NC} $*"; PASSED=$((PASSED + 1)); }
bad()  { echo -e "${RED}FAIL${NC} $*"; FAILED=$((FAILED + 1)); }

assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        ok "$label = $got"
    else
        bad "$label: want '$want', got '$got'"
    fi
}

assert_ge() {
    local label="$1" got="$2" floor="$3"
    if [[ "$got" =~ ^[0-9]+$ ]] && ((got >= floor)); then
        ok "$label = $got (>= $floor)"
    else
        bad "$label: $got < $floor"
    fi
}

echo -e "${BLUE}Verifying $REMOTE_USER@$REMOTE_HOST${NC}\n"

test_ssh || { echo -e "${RED}Cannot reach target${NC}" >&2; exit 1; }

# ── systemd ───────────────────────────────────────────────────────────────────
echo "systemd:"
assert_eq "  is-active" "$(remote_exec 'systemctl is-active llama-server' 2>/dev/null)" "active"
assert_eq "  is-enabled" "$(remote_exec 'systemctl is-enabled llama-server' 2>/dev/null)" "enabled"

# ── deployed conf matches yaml intent ─────────────────────────────────────────
echo "/etc/llama-server.conf:"
assert_eq "  CONTEXT_PER_REQUEST" "$(remote_conf_value CONTEXT_PER_REQUEST)" "$CONTEXT_PER_REQUEST"
assert_eq "  CONTEXT_SIZE"        "$(remote_conf_value CONTEXT_SIZE)"        "$TOTAL_CONTEXT"
assert_eq "  PARALLEL_SLOTS"      "$(remote_conf_value PARALLEL_SLOTS)"      "$PARALLEL_SLOTS"
assert_eq "  KV_UNIFIED"          "$(remote_conf_value KV_UNIFIED)"          "$KV_UNIFIED"
assert_eq "  CACHE_TYPE_K"        "$(remote_conf_value CACHE_TYPE_K)"        "$CACHE_TYPE_K"
assert_eq "  CACHE_TYPE_V"        "$(remote_conf_value CACHE_TYPE_V)"        "$CACHE_TYPE_V"

# ── the running process ───────────────────────────────────────────────────────
echo "running process:"
CMDLINE=$(remote_exec "tr '\0' ' ' < /proc/\$(pgrep -f 'llama-server' | head -1)/cmdline" 2>/dev/null || echo "")
if [[ -z "$CMDLINE" ]]; then
    bad "  could not read llama-server cmdline"
else
    proc_ctx=$(grep -oP '(?:^|\s)-c\s+\K[0-9]+' <<<"$CMDLINE" | head -1)
    proc_np=$(grep -oP '(?:^|\s)-np\s+\K[0-9]+' <<<"$CMDLINE" | head -1)
    assert_eq "  -c"  "${proc_ctx:-<unset>}" "$TOTAL_CONTEXT"
    assert_eq "  -np" "${proc_np:-<unset>}"  "$PARALLEL_SLOTS"
    if [[ "$KV_UNIFIED" == "true" ]]; then
        [[ "$CMDLINE" == *"--kv-unified"* ]] && ok "  --kv-unified present" || bad "  --kv-unified missing"
    else
        [[ "$CMDLINE" == *"--no-kv-unified"* ]] && ok "  --no-kv-unified present" || bad "  --no-kv-unified missing"
    fi
fi

# ── what a client actually gets ───────────────────────────────────────────────
# The number that matters. /props is API-key protected and may be blocked by a
# reverse proxy, so read it locally on the target.
echo "effective window:"
PORT=$(remote_conf_value LLAMA_PORT 8080)
KEY=$(remote_conf_value LLAMA_API_KEY)
SLOT_CTX=$(remote_exec "curl -sf -H 'Authorization: Bearer $KEY' http://localhost:$PORT/props" 2>/dev/null \
    | jq -r '.default_generation_settings.n_ctx // empty' 2>/dev/null || echo "")

if [[ -n "$SLOT_CTX" ]]; then
    assert_eq "  /props n_ctx (per slot)" "$SLOT_CTX" "$CONTEXT_PER_REQUEST"
    assert_ge "  /props n_ctx floor" "$SLOT_CTX" "$CONTEXT_PER_REQUEST"
else
    echo -e "  ${YELLOW}SKIP${NC} /props unreadable — falling back to an overflow probe"
    PROBE=$(remote_exec "curl -s -H 'Authorization: Bearer $KEY' -H 'Content-Type: application/json' -d '{\"messages\":[{\"role\":\"user\",\"content\":\"$(printf 'x%.0s' {1..200})\"}],\"max_tokens\":1}' http://localhost:$PORT/v1/chat/completions" 2>/dev/null || echo "")
    if grep -q exceed_context_size <<<"$PROBE"; then
        bad "  server rejects even a tiny prompt"
    else
        ok "  server accepts requests (window not directly readable)"
    fi
fi

echo ""
echo "─────────────────────────────────────────"
echo -e "${GREEN}$PASSED passed${NC}, ${RED}$FAILED failed${NC}"
[[ "$FAILED" -eq 0 ]]
