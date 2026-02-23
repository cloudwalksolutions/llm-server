#!/bin/bash
# Test LLM server locally
set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

if [[ -f /etc/llama-server.conf ]]; then
    source /etc/llama-server.conf
fi
LLAMA_PORT="${LLAMA_PORT:-8080}"
ENDPOINT="http://localhost:$LLAMA_PORT"

AUTH_HEADER=()
if [[ -n "${LLAMA_API_KEY:-}" ]]; then
    AUTH_HEADER=(-H "Authorization: Bearer $LLAMA_API_KEY")
fi

echo -e "${BLUE}Testing LLaMA server (local)${NC}"
echo -e "Endpoint: ${BLUE}$ENDPOINT${NC}"
if [[ -n "${LLAMA_API_KEY:-}" ]]; then
    echo -e "Auth:     ${BLUE}Bearer token${NC}"
fi
echo ""

# Health check
health=$(curl -s -o /dev/null -w "%{http_code}" "$ENDPOINT/health" 2>/dev/null)
if [[ "$health" != "200" ]]; then
    echo -e "${RED}FAIL${NC}: Server not healthy (HTTP $health)"
    echo ""
    echo -e "  llama-server service: ${YELLOW}$(systemctl is-active llama-server 2>/dev/null || echo 'unknown')${NC}"
    echo -e "  container:            ${YELLOW}$(podman ps --filter name=llama-server-container --format '{{.Status}}' 2>/dev/null || echo 'not running')${NC}"
    exit 1
fi
echo -e "Health: ${GREEN}OK${NC}"
echo ""

# Chat completion
echo "Sending test prompt..."
echo ""
result=$(curl -s --max-time 120 "$ENDPOINT/v1/chat/completions" \
    -H "Content-Type: application/json" \
    ${AUTH_HEADER[@]+"${AUTH_HEADER[@]}"} \
    -d '{
        "messages": [{"role": "user", "content": "Say hello in exactly 5 words."}],
        "max_tokens": 50,
        "temperature": 0.7
    }' 2>/dev/null)

if command -v jq &>/dev/null; then
    response=$(echo "$result" | jq -r '.choices[0].message | if .content and .content != "" then .content elif .reasoning_content then .reasoning_content else empty end')
    if [[ -n "$response" ]]; then
        echo -e "Response: ${GREEN}$response${NC}"
        echo ""
        echo -e "Model:  $(echo "$result" | jq -r '.model // "unknown"')"
        echo -e "Tokens: $(echo "$result" | jq -r '(.usage.prompt_tokens // 0) + (.usage.completion_tokens // 0)')"
    else
        echo -e "${RED}FAIL${NC}: No response from server"
        echo "$result" | jq . 2>/dev/null || echo "$result"
        exit 1
    fi
else
    echo "$result"
fi
# Streaming test
echo ""
echo -e "${BLUE}Streaming test${NC}..."
echo ""
_stream_py=$(mktemp)
cat > "$_stream_py" <<'PYEOF'
import sys, json, time

first_token_time = None
last_token_time = None
token_count = 0

for line in sys.stdin:
    line = line.rstrip('\n')
    if not line.startswith('data: '):
        continue
    payload = line[6:]
    if payload == '[DONE]':
        break
    try:
        obj = json.loads(payload)
        delta = obj.get('choices', [{}])[0].get('delta', {})
        text = delta.get('content') or delta.get('reasoning_content') or ''
        if text:
            now = time.monotonic()
            if first_token_time is None:
                first_token_time = now
            last_token_time = now
            token_count += 1
            print(text, end='', flush=True)
    except (json.JSONDecodeError, KeyError, IndexError):
        pass

print()
print()
if token_count > 0 and first_token_time is not None and last_token_time is not None:
    elapsed = last_token_time - first_token_time
    tps = token_count / elapsed if elapsed > 0 else float('inf')
    print(f'\033[0;34m\u25b8 {token_count} tok \u00b7 {elapsed:.1f}s \u00b7 {tps:.1f} tok/s\033[0m')
PYEOF
curl -sN --max-time 180 "$ENDPOINT/v1/chat/completions" \
    -H "Content-Type: application/json" \
    ${AUTH_HEADER[@]+"${AUTH_HEADER[@]}"} \
    -d '{
        "messages": [{"role": "user", "content": "Explain in detail why Michael Jordan is greater than LeBron James."}],
        "max_tokens": 150,
        "temperature": 0.7,
        "stream": true
    }' 2>/dev/null \
    | python3 -u "$_stream_py"
rm -f "$_stream_py"
echo -e "${GREEN}PASS${NC}: Local test complete"
