#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source .env 2>/dev/null || true

# Resolve endpoint: config/llama.yaml > LLM_HOST env
if [[ -f config/llama.yaml ]] && command -v yq &>/dev/null; then
    REMOTE_HOST=$(yq '.remote.host' config/llama.yaml)
    LLM_ENDPOINT="http://${REMOTE_HOST}:8080"
elif [[ -n "${LLM_HOST:-}" ]]; then
    LLM_ENDPOINT="https://${LLM_HOST}"
else
    echo "ERROR: No target found. Configure config/llama.yaml or set LLM_HOST in .env."
    exit 1
fi

export LLM_ENDPOINT LLAMA_API_KEY

echo ""
echo "🚀 LLM Server Load Test (k6)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📅 $(date +"%Y-%m-%d %H:%M:%S")"
echo "🌐 Endpoint: ${LLM_ENDPOINT}"
echo "📊 Test profile:"
echo "   • 10s warmup (1 user)"
echo "   • 30s ramp up (1→4 users)"
echo "   • 1m load test (4→8 users)"
echo "   • 30s ramp down (8→4 users)"
echo "   • 10s cooldown (4→1 user)"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Run k6
k6 run "$SCRIPT_DIR/benchmark.k6.js"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✨ Load test complete!"
echo ""
