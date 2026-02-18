#!/bin/bash
# Test that model selection works via API
# Usage: ./tests/test-model-selection.sh [test-name]
#   ONE TEST AT A TIME: ./tests/test-model-selection.sh test_api_lists_models
#   ALL TESTS:          ./tests/test-model-selection.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

source .env 2>/dev/null || true

GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

HOST="${LLM_HOST:-}"
if [[ -z "$HOST" ]]; then
    echo -e "${RED}FAIL${NC}: LLM_HOST not set in .env"
    exit 1
fi

ENDPOINT="https://$HOST"
API_KEY="${LLAMA_API_KEY:-}"

AUTH_HEADER=()
[[ -n "$API_KEY" ]] && AUTH_HEADER=(-H "Authorization: Bearer $API_KEY")

# ── TEST 1 ────────────────────────────────────────────────────────────────────
test_api_lists_models() {
    echo "TEST: GET /v1/models returns at least one model"
    result=$(curl -s --max-time 15 "$ENDPOINT/v1/models" \
        -H "Content-Type: application/json" \
        ${AUTH_HEADER[@]+"${AUTH_HEADER[@]}"})

    count=$(echo "$result" | jq '.data | length' 2>/dev/null || echo "0")
    if [[ "$count" -lt 1 ]]; then
        echo -e "${RED}FAIL${NC}: /v1/models returned 0 models"
        echo "$result" | jq . 2>/dev/null || echo "$result"
        exit 1
    fi
    model_id=$(echo "$result" | jq -r '.data[0].id' 2>/dev/null)
    echo -e "${GREEN}PASS${NC}: /v1/models returned $count model(s) (active: $model_id)"
}

# ── TEST 2 ────────────────────────────────────────────────────────────────────
test_completion_reports_model() {
    echo "TEST: Chat completion response includes .model field and content"
    result=$(curl -s --max-time 60 "$ENDPOINT/v1/chat/completions" \
        -H "Content-Type: application/json" \
        ${AUTH_HEADER[@]+"${AUTH_HEADER[@]}"} \
        -d '{"messages":[{"role":"user","content":"Reply with one word: OK"}],"max_tokens":10}')

    model_field=$(echo "$result" | jq -r '.model // ""' 2>/dev/null)
    if [[ -z "$model_field" ]]; then
        echo -e "${RED}FAIL${NC}: .model field missing from completion response"
        echo "$result" | jq . 2>/dev/null || echo "$result"
        exit 1
    fi

    content=$(echo "$result" | jq -r '.choices[0].message | if .content and .content != "" then .content elif .reasoning_content then .reasoning_content else "" end' 2>/dev/null)
    if [[ -z "$content" ]]; then
        echo -e "${RED}FAIL${NC}: No content in completion response"
        echo "$result" | jq . 2>/dev/null || echo "$result"
        exit 1
    fi
    echo -e "${GREEN}PASS${NC}: model=$model_field, content=$(echo "$content" | head -c 60)"
}

# ── TEST 3 ────────────────────────────────────────────────────────────────────
test_active_model_matches_config() {
    echo "TEST: API .model matches remote /etc/llama-server.conf MODEL_FILE"

    result=$(curl -s --max-time 60 "$ENDPOINT/v1/chat/completions" \
        -H "Content-Type: application/json" \
        ${AUTH_HEADER[@]+"${AUTH_HEADER[@]}"} \
        -d '{"messages":[{"role":"user","content":"Hi"}],"max_tokens":5}')
    api_model=$(echo "$result" | jq -r '.model // ""' 2>/dev/null)

    if [[ -z "$api_model" ]]; then
        echo -e "${RED}FAIL${NC}: .model field missing from API response"
        echo "$result" | jq . 2>/dev/null || echo "$result"
        exit 1
    fi

    source scripts/lib/common.sh
    load_config || { echo -e "${RED}FAIL${NC}: Cannot load config"; exit 1; }
    conf_model=$(remote_exec "grep '^MODEL_FILE=' /etc/llama-server.conf 2>/dev/null | cut -d= -f2" || echo "")

    if [[ -z "$conf_model" ]]; then
        echo -e "${RED}FAIL${NC}: Cannot read MODEL_FILE from remote config"
        exit 1
    fi

    conf_basename=$(basename "$conf_model")
    if [[ "$api_model" != *"$conf_basename"* ]]; then
        echo -e "${RED}FAIL${NC}: API model '$api_model' != config '$conf_basename'"
        exit 1
    fi
    echo -e "${GREEN}PASS${NC}: API model '$api_model' matches config '$conf_basename'"
}

# ── TEST 4 ────────────────────────────────────────────────────────────────────
test_model_file_exists_on_remote() {
    echo "TEST: Active MODEL_FILE exists at /opt/llm/models/ on remote"

    source scripts/lib/common.sh
    load_config || { echo -e "${RED}FAIL${NC}: Cannot load config"; exit 1; }
    conf_model=$(remote_exec "grep '^MODEL_FILE=' /etc/llama-server.conf 2>/dev/null | cut -d= -f2" || echo "")

    if [[ -z "$conf_model" ]]; then
        echo -e "${RED}FAIL${NC}: Cannot read MODEL_FILE from remote config"
        exit 1
    fi

    if ! remote_exec "test -f '/opt/llm/models/$conf_model'"; then
        echo -e "${RED}FAIL${NC}: /opt/llm/models/$conf_model not found on remote"
        exit 1
    fi
    SIZE=$(remote_exec "du -h '/opt/llm/models/$conf_model' | cut -f1")
    echo -e "${GREEN}PASS${NC}: /opt/llm/models/$conf_model exists ($SIZE)"
}

# ── TEST 5 ────────────────────────────────────────────────────────────────────
test_per_request_model_selection() {
    echo "TEST: Client can select a non-default model per-request via API"

    models_result=$(curl -s --max-time 15 "$ENDPOINT/v1/models" \
        -H "Content-Type: application/json" \
        ${AUTH_HEADER[@]+"${AUTH_HEADER[@]}"})

    model_count=$(echo "$models_result" | jq '.data | length' 2>/dev/null || echo "0")
    if [[ "$model_count" -lt 2 ]]; then
        echo "SKIP: Only $model_count model(s) available via /v1/models — need 2+ to prove selection"
        echo "      Ensure router mode is deployed (make deploy) and multiple models exist (make list-models)"
        return 0
    fi

    default_model=$(echo "$models_result" | jq -r '.data[0].id')
    target_model=$(echo "$models_result" | jq -r '.data[1].id')
    echo "  Default: $default_model"
    echo "  Requesting: $target_model"

    result=$(curl -s --max-time 90 "$ENDPOINT/v1/chat/completions" \
        -H "Content-Type: application/json" \
        ${AUTH_HEADER[@]+"${AUTH_HEADER[@]}"} \
        -d "{\"model\": \"$target_model\", \"messages\":[{\"role\":\"user\",\"content\":\"Hi\"}], \"max_tokens\":5}")

    response_model=$(echo "$result" | jq -r '.model // ""' 2>/dev/null)
    if [[ -z "$response_model" ]]; then
        echo -e "${RED}FAIL${NC}: No .model in response"
        echo "$result" | jq . 2>/dev/null || echo "$result"
        exit 1
    fi
    if [[ "$response_model" != *"$target_model"* ]]; then
        echo -e "${RED}FAIL${NC}: Requested '$target_model' but got '$response_model'"
        echo "       Router mode may not be active — run: make deploy"
        exit 1
    fi
    echo -e "${GREEN}PASS${NC}: Requested '$target_model', API confirmed '$response_model'"
}

# ── RUNNER ────────────────────────────────────────────────────────────────────
echo -e "${BLUE}Testing model selection (remote: $HOST)${NC}"
echo ""

if [[ $# -ge 1 ]]; then
    "$1"
else
    test_api_lists_models
    echo ""
    test_completion_reports_model
    echo ""
    test_active_model_matches_config
    echo ""
    test_model_file_exists_on_remote
    echo ""
    test_per_request_model_selection
    echo ""
    echo -e "${GREEN}PASS${NC}: All model selection tests passed"
fi
