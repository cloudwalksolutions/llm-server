#!/bin/bash
# Test LLM server over Cloudflare Tunnel (DNS)
set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

if [[ ! -f /etc/cloudflared/config.yml ]]; then
    echo -e "${RED}FAIL${NC}: No Cloudflare Tunnel configured"
    exit 1
fi

source /etc/llama-server.conf 2>/dev/null || true

CF_HOST=$(grep 'hostname:' /etc/cloudflared/config.yml | head -1 | awk '{print $3}')
if [[ -z "$CF_HOST" ]]; then
    echo -e "${RED}FAIL${NC}: Could not read hostname from /etc/cloudflared/config.yml"
    exit 1
fi

ENDPOINT="https://$CF_HOST"

AUTH_HEADER=()
if [[ -n "${LLAMA_API_KEY:-}" ]]; then
    AUTH_HEADER=(-H "Authorization: Bearer $LLAMA_API_KEY")
fi

echo -e "${BLUE}Testing LLaMA server (DNS: $CF_HOST)${NC}"
echo -e "Endpoint: ${BLUE}$ENDPOINT${NC}"
if [[ -n "${LLAMA_API_KEY:-}" ]]; then
    echo -e "Auth:     ${BLUE}Bearer token${NC}"
fi
echo ""

# Health check
health=$(curl -s -o /dev/null -w "%{http_code}" "$ENDPOINT/health" 2>/dev/null)
if [[ "$health" != "200" ]]; then
    echo -e "${RED}FAIL${NC}: Server not reachable via tunnel (HTTP $health)"
    echo ""
    echo -e "  cloudflared service:  ${YELLOW}$(systemctl is-active cloudflared 2>/dev/null || echo 'unknown')${NC}"
    echo -e "  llama-server service: ${YELLOW}$(systemctl is-active llama-server 2>/dev/null || echo 'unknown')${NC}"
    echo -e "  DNS resolves:         ${YELLOW}$(host "$CF_HOST" 2>/dev/null | head -1 || echo 'FAIL')${NC}"
    exit 1
fi
echo -e "Health: ${GREEN}OK${NC}"
echo ""

# Chat completion
echo "Sending test prompt..."
echo ""
result=$(curl -s --max-time 120 "$ENDPOINT/v1/chat/completions" \
    -H "Content-Type: application/json" \
    "${AUTH_HEADER[@]}" \
    -d '{
        "messages": [{"role": "user", "content": "Say hello in exactly 5 words."}],
        "max_tokens": 50,
        "temperature": 0.7
    }' 2>/dev/null)

if command -v jq &>/dev/null; then
    response=$(echo "$result" | jq -r '.choices[0].message.content // empty')
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
curl -sN --max-time 180 "$ENDPOINT/v1/chat/completions" \
    -H "Content-Type: application/json" \
    "${AUTH_HEADER[@]}" \
    -d '{
        "messages": [{"role": "user", "content": "Explain in detail why Michael Jordan is greater than LeBron James."}],
        "max_tokens": 500,
        "temperature": 0.7,
        "stream": true
    }' 2>/dev/null \
    | sed -u 's/^data: //' \
    | grep -v '^\[DONE\]' \
    | jq --unbuffered -j 'if .choices[0].delta.content then .choices[0].delta.content else empty end' 2>/dev/null
echo ""
echo ""
echo -e "${GREEN}PASS${NC}: DNS test complete"
