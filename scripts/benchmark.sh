#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load environment
if [[ -f .env ]]; then
    source .env
    export LLM_HOST LLAMA_API_KEY
fi

echo ""
echo "🚀 LLM Server Load Test (k6)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📅 $(date +"%Y-%m-%d %H:%M:%S")"
echo "🌐 Endpoint: https://${LLM_HOST}"
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
