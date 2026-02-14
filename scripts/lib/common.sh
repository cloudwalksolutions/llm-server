#!/usr/bin/env bash
# Common utilities for llama-server scripts

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Load YAML config and export as environment variables
load_config() {
    local config_file="${1:-config/llama.yaml}"

    if [[ ! -f "$config_file" ]]; then
        echo -e "${RED}Error: $config_file not found${NC}" >&2
        echo "Run 'make setup' to create configuration" >&2
        return 1
    fi

    # Parse YAML using yq
    REMOTE_HOST=$(yq '.remote.host' "$config_file")
    REMOTE_USER=$(yq '.remote.user' "$config_file")
    PARALLEL_SLOTS=$(yq '.llama.parallel_slots' "$config_file")
    BATCH_SIZE=$(yq '.llama.batch_size' "$config_file")
    UBATCH_SIZE=$(yq '.llama.ubatch_size' "$config_file")
    THREADS_GEN=$(yq '.llama.threads_gen' "$config_file")
    THREADS_BATCH=$(yq '.llama.threads_batch' "$config_file")
    THREADS_HTTP=$(yq '.llama.threads_http' "$config_file")
    CACHE_REUSE=$(yq '.llama.cache_reuse' "$config_file")
    CONTEXT_SIZE=$(yq '.llama.context_size' "$config_file")

    # Load SSH auth from .env
    if [[ -f .env ]]; then
        source .env
    fi

    # Determine SSH method (SSH_KEY takes precedence over SSH_PASS)
    if [[ -n "${SSH_KEY:-}" ]]; then
        SSH_AUTH="key"
        SSH_KEY="${SSH_KEY/#\~/$HOME}"
    elif [[ -n "${SSH_PASS:-}" ]]; then
        SSH_AUTH="password"
    else
        echo -e "${RED}Error: No SSH authentication configured${NC}" >&2
        echo "Set SSH_KEY or SSH_PASS in .env" >&2
        return 1
    fi

    export REMOTE_HOST REMOTE_USER SSH_AUTH SSH_KEY SSH_PASS
    export PARALLEL_SLOTS BATCH_SIZE UBATCH_SIZE
    export THREADS_GEN THREADS_BATCH THREADS_HTTP
    export CACHE_REUSE CONTEXT_SIZE
}

# Build SSH command based on auth method
_ssh_cmd() {
    if [[ "$SSH_AUTH" == "key" ]]; then
        echo "ssh -i \"$SSH_KEY\" -o StrictHostKeyChecking=no"
    else
        echo "sshpass -p \"$SSH_PASS\" ssh -o StrictHostKeyChecking=no"
    fi
}

# Test SSH connection
test_ssh() {
    eval "$(_ssh_cmd) -o ConnectTimeout=5 \"$REMOTE_USER@$REMOTE_HOST\" \"true\"" 2>/dev/null
}

# Execute command on remote server
remote_exec() {
    eval "$(_ssh_cmd) \"$REMOTE_USER@$REMOTE_HOST\" \"\$@\""
}

# Execute command with sudo on remote server
remote_exec_sudo() {
    if [[ "$SSH_AUTH" == "password" ]]; then
        eval "$(_ssh_cmd) \"$REMOTE_USER@$REMOTE_HOST\" \"echo '$SSH_PASS' | sudo -S \$*\""
    else
        eval "$(_ssh_cmd) \"$REMOTE_USER@$REMOTE_HOST\" \"sudo \$*\""
    fi
}

# Pretty print configuration
print_config() {
    echo -e "${YELLOW}Concurrency:${NC} $PARALLEL_SLOTS slots"
    echo -e "${YELLOW}Batching:${NC} $BATCH_SIZE logical / $UBATCH_SIZE physical"
    echo -e "${YELLOW}Threading:${NC} $THREADS_GEN gen / $THREADS_BATCH batch / $THREADS_HTTP HTTP"
    echo -e "${YELLOW}Caching:${NC} $CACHE_REUSE token threshold"
    echo -e "${YELLOW}Context:${NC} $CONTEXT_SIZE tokens"
}
