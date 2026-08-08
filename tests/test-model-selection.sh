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
    echo "TEST: each instance's API model name is served by its own config"

    source scripts/lib/common.sh
    load_config || { echo -e "${RED}FAIL${NC}: Cannot load config"; exit 1; }

    for name in "${INSTANCE_NAMES[@]}"; do
        load_instance "$name" || { echo -e "${RED}FAIL${NC}: bad config for $name"; exit 1; }

        result=$(curl -s --max-time 90 "$ENDPOINT/v1/chat/completions" \
            -H "Content-Type: application/json" \
            ${AUTH_HEADER[@]+"${AUTH_HEADER[@]}"} \
            -d "{\"model\":\"$name\",\"messages\":[{\"role\":\"user\",\"content\":\"Hi\"}],\"max_tokens\":5}")
        api_model=$(echo "$result" | jq -r '.model // ""' 2>/dev/null)

        if [[ "$api_model" != "$name" ]]; then
            echo -e "${RED}FAIL${NC}: asked for '$name', server answered as '$api_model'"
            exit 1
        fi

        conf_model=$(remote_conf_value "$INSTANCES_DIR/$name.conf" MODEL_FILE)
        if [[ "$conf_model" != "$INST_MODEL_FILE" ]]; then
            echo -e "${RED}FAIL${NC}: $name deployed MODEL_FILE '$conf_model' != config '$INST_MODEL_FILE'"
            exit 1
        fi
        echo -e "  ${GREEN}ok${NC} $name -> $conf_model"
    done
    echo -e "${GREEN}PASS${NC}: every instance answers as itself and matches its deployed config"
}

# ── TEST 4 ────────────────────────────────────────────────────────────────────
test_model_file_exists_on_remote() {
    echo "TEST: every instance's model file exists on the target"

    source scripts/lib/common.sh
    load_config || { echo -e "${RED}FAIL${NC}: Cannot load config"; exit 1; }

    for name in "${INSTANCE_NAMES[@]}"; do
        load_instance "$name" || { echo -e "${RED}FAIL${NC}: bad config for $name"; exit 1; }
        if ! remote_exec "test -f '/opt/llm/models/$INST_MODEL_FILE'"; then
            echo -e "${RED}FAIL${NC}: /opt/llm/models/$INST_MODEL_FILE missing (instance $name)"
            exit 1
        fi
        size=$(remote_exec "du -h '/opt/llm/models/$INST_MODEL_FILE' | cut -f1")
        echo -e "  ${GREEN}ok${NC} $name -> $INST_MODEL_FILE ($size)"
    done
    echo -e "${GREEN}PASS${NC}: all instance model files present"
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
