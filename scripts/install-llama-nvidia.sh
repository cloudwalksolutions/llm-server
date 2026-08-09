#!/bin/bash
set -euo pipefail

# =============================================================================
# Walker's PC LLM Server Bootstrap Script
# NVIDIA RTX 4060 Ti - Ubuntu/Linux Mint
# =============================================================================

# Configuration
LLAMA_PORT="${LLAMA_PORT:-8080}"
LLAMA_HOST="${LLAMA_HOST:-0.0.0.0}"
MODELS_DIR="/opt/llm/models"
CONTEXT_SIZE="${CONTEXT_SIZE:-32768}"
CONTAINER_IMAGE="ghcr.io/ggml-org/llama.cpp:server-cuda"

# Models to download
SMALL_MODEL_REPO="Qwen/Qwen3-8B-GGUF"
SMALL_MODEL_FILE="Qwen3-8B-Q4_K_M.gguf"

MID_MODEL_REPO="Qwen/Qwen3-14B-GGUF"
MID_MODEL_FILE="Qwen3-14B-Q4_K_M.gguf"

BEST_MODEL_REPO="unsloth/DeepSeek-R1-Distill-Qwen-32B-GGUF"
BEST_MODEL_FILE="DeepSeek-R1-Distill-Qwen-32B-Q4_K_M.gguf"

DEFAULT_MODEL="$MID_MODEL_FILE"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

check_sudo() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run with sudo"
        echo "Usage: sudo ./install-llama-nvidia.sh"
        exit 1
    fi
}

get_actual_user() {
    ACTUAL_USER="${SUDO_USER:-$USER}"
    if [[ "$ACTUAL_USER" == "root" ]]; then
        log_error "Please run this script with sudo from a non-root user"
        exit 1
    fi
    ACTUAL_USER_HOME=$(getent passwd "$ACTUAL_USER" | cut -d: -f6)
    ACTUAL_USER_ID=$(id -u "$ACTUAL_USER")
    ACTUAL_USER_GID=$(id -g "$ACTUAL_USER")
}

# =============================================================================
# Phase 1: System Setup
# =============================================================================
phase1_system_setup() {
    log_step "Phase 1: System setup"

    log_info "Updating system packages..."
    apt-get update -q
    apt-get install -y curl wget jq byobu ca-certificates gnupg

    # Install docker-ce (system Docker) — needed for systemd service
    # Rancher Desktop / snap docker don't provide /usr/bin/docker or the docker group
    if ! dpkg -l docker-ce 2>/dev/null | grep -q '^ii'; then
        log_info "Installing Docker CE..."
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" \
            > /etc/apt/sources.list.d/docker.list
        apt-get update -q
        apt-get install -y docker-ce docker-ce-cli containerd.io
        systemctl enable docker
        systemctl start docker
    else
        log_info "Docker CE already installed"
    fi

    # Install NVIDIA Container Toolkit if not present
    if ! dpkg -l nvidia-container-toolkit &>/dev/null; then
        log_info "Installing NVIDIA Container Toolkit..."
        curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
            | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
        curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
            | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
            > /etc/apt/sources.list.d/nvidia-container-toolkit.list
        apt-get update -q
        apt-get install -y nvidia-container-toolkit
        nvidia-ctk runtime configure --runtime=docker
        systemctl restart docker
    else
        log_info "NVIDIA Container Toolkit already installed"
    fi

    mkdir -p "$MODELS_DIR"
    mkdir -p /opt/llm/bin
    chmod 755 "$MODELS_DIR" /opt/llm /opt/llm/bin

    log_info "Phase 1 complete ✓"
}

# =============================================================================
# Phase 2: User and Group Configuration
# =============================================================================
phase2_user_setup() {
    log_step "Phase 2: User and group configuration"

    get_actual_user

    log_info "Adding $ACTUAL_USER to docker group..."
    usermod -aG docker "$ACTUAL_USER"

    chown -R "$ACTUAL_USER:$ACTUAL_USER" /opt/llm

    log_info "Phase 2 complete ✓"
}

# =============================================================================
# Phase 3: Container Setup
# =============================================================================
phase3_container_setup() {
    log_step "Phase 3: Container setup"

    log_info "Pulling llama.cpp CUDA container image..."
    docker pull "$CONTAINER_IMAGE"

    log_info "Testing NVIDIA GPU access in container..."
    if docker run --rm --gpus all "$CONTAINER_IMAGE" nvidia-smi 2>/dev/null | grep -q "NVIDIA"; then
        log_info "NVIDIA GPU accessible in container ✓"
    else
        log_warn "GPU test inconclusive — make sure NVIDIA drivers are installed and nvidia-smi works on the host"
    fi

    log_info "Phase 3 complete ✓"
}

# =============================================================================
# Phase 4: Model Downloads
# =============================================================================
phase4_model_download() {
    log_step "Phase 4: Downloading models"

    get_actual_user

    # Install hf CLI
    if ! command -v hf &>/dev/null; then
        log_info "Installing Hugging Face CLI..."
        curl -fsSL https://huggingface.co/cli/install.sh | HF_CLI_BIN_DIR=/usr/local/bin bash
    else
        log_info "Hugging Face CLI already installed"
    fi

    export HF_HUB_CACHE="$MODELS_DIR/.cache"

    # Check VRAM and warn about model fits
    VRAM_MB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 || echo "0")
    if [[ "$VRAM_MB" -gt 0 ]]; then
        log_info "Detected ${VRAM_MB}MB VRAM"
        if [[ "$VRAM_MB" -lt 9000 ]]; then
            log_warn "8GB VRAM: 8B model will fully offload to GPU, 14B may spill to CPU"
        else
            log_info "16GB VRAM: all models fit on GPU ✓"
        fi
    fi

    SMALL_MODEL_PATH="$MODELS_DIR/$SMALL_MODEL_FILE"
    if [[ -f "$SMALL_MODEL_PATH" ]]; then
        log_info "Small model already exists: $SMALL_MODEL_FILE"
    else
        log_info "Downloading small model: $SMALL_MODEL_FILE (~5GB)..."
        hf download "$SMALL_MODEL_REPO" "$SMALL_MODEL_FILE" --local-dir "$MODELS_DIR"
        log_info "Small model downloaded ✓"
    fi

    MID_MODEL_PATH="$MODELS_DIR/$MID_MODEL_FILE"
    if [[ -f "$MID_MODEL_PATH" ]]; then
        log_info "14B model already exists: $MID_MODEL_FILE"
    else
        log_info "Downloading 14B thinking model: $MID_MODEL_FILE (~8GB)..."
        hf download "$MID_MODEL_REPO" "$MID_MODEL_FILE" --local-dir "$MODELS_DIR"
        log_info "14B model downloaded ✓"
    fi

    BEST_MODEL_PATH="$MODELS_DIR/$BEST_MODEL_FILE"
    if [[ -f "$BEST_MODEL_PATH" ]]; then
        log_info "Best model already exists: $BEST_MODEL_FILE"
    else
        log_info "Downloading best 32B model: $BEST_MODEL_FILE (~20GB)..."
        log_info "This will take a while, please be patient..."
        hf download "$BEST_MODEL_REPO" "$BEST_MODEL_FILE" --local-dir "$MODELS_DIR"
        log_info "Best model downloaded ✓"
    fi

    rm -rf "$MODELS_DIR/.cache"
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$MODELS_DIR"

    log_info "Phase 4 complete ✓"
    echo ""
    log_info "Downloaded models:"
    echo "  - $SMALL_MODEL_FILE (fast, ~5GB)"
    echo "  - $MID_MODEL_FILE (thinking+content, ~8GB)"
    echo "  - $BEST_MODEL_FILE (best quality, ~20GB)"
}

# =============================================================================
# Phase 5: Systemd Service Setup
# =============================================================================
phase5_service_setup() {
    log_step "Phase 5: Systemd service configuration"

    get_actual_user

    # Create model switcher script
    cat > /opt/llm/bin/llm-switch << 'EOF'
#!/bin/bash
MODELS_DIR="/opt/llm/models"
CONFIG_FILE="/etc/llama-server.conf"

list_models() {
    echo "Available models:"
    current=$(grep "^MODEL_FILE=" "$CONFIG_FILE" 2>/dev/null | cut -d= -f2)
    for f in "$MODELS_DIR"/*.gguf; do
        [[ -f "$f" ]] || continue
        name=$(basename "$f")
        size=$(du -h "$f" | cut -f1)
        if [[ "$name" == "$current" ]]; then
            echo "  * $name ($size) [ACTIVE]"
        else
            echo "    $name ($size)"
        fi
    done
}

switch_model() {
    local model="$1"
    local model_path="$MODELS_DIR/$model"

    if [[ ! -f "$model_path" ]]; then
        echo "Error: Model not found: $model"
        echo "Run 'llm-switch' to see available models"
        exit 1
    fi

    sudo sed -i "s|^MODEL_FILE=.*|MODEL_FILE=$model|" "$CONFIG_FILE"
    echo "Switched to: $model"
    echo ""
    echo "Restart service to apply:"
    echo "  sudo systemctl restart llama-server"
}

case "${1:-}" in
    list|ls|"")
        list_models
        ;;
    *)
        switch_model "$1"
        ;;
esac
EOF
    chmod +x /opt/llm/bin/llm-switch

    # Create config file (only if missing — preserve user changes from llm-switch)
    if [[ ! -f /etc/llama-server.conf ]]; then
        GENERATED_API_KEY=$(openssl rand -hex 32)
        cat > /etc/llama-server.conf << EOF
# LLaMA Server Configuration
# Edit and restart: sudo systemctl restart llama-server
# Switch models: llm-switch <model-filename>

LLAMA_PORT=$LLAMA_PORT
LLAMA_HOST=$LLAMA_HOST
CONTEXT_SIZE=$CONTEXT_SIZE
MODEL_FILE=$DEFAULT_MODEL
CONTAINER_IMAGE=$CONTAINER_IMAGE

# API key for bearer-token auth (remove or leave empty to disable)
LLAMA_API_KEY=$GENERATED_API_KEY
EOF
        log_info "Created /etc/llama-server.conf"
    else
        log_info "/etc/llama-server.conf already exists, preserving"
    fi

    # Create systemd service using docker with NVIDIA GPU passthrough
    cat > /etc/systemd/system/llama-server.service << 'EOF'
[Unit]
Description=LLaMA.cpp Inference Server (NVIDIA CUDA)
After=network.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=simple
EnvironmentFile=/etc/llama-server.conf

ExecStartPre=-/usr/bin/docker rm -f llama-server-container
ExecStart=/usr/bin/docker run \
    --name llama-server-container \
    --rm \
    --gpus all \
    -v /opt/llm/models:/models:ro \
    -p ${LLAMA_PORT}:${LLAMA_PORT} \
    -e LLAMA_API_KEY=${LLAMA_API_KEY} \
    ${CONTAINER_IMAGE} \
    --no-mmap \
    -ngl 999 \
    -fa on \
    -c ${CONTEXT_SIZE} \
    --models-dir /models \
    -m /models/${MODEL_FILE} \
    --host 0.0.0.0 \
    --port ${LLAMA_PORT} \
    --metrics

ExecStop=/usr/bin/docker stop llama-server-container

Restart=always
RestartSec=10
TimeoutStartSec=300

LimitNOFILE=65535
LimitMEMLOCK=infinity

StandardOutput=journal
StandardError=journal
SyslogIdentifier=llama-server

[Install]
WantedBy=multi-user.target
EOF

    # Add llm tools to PATH
    cat > /etc/profile.d/llm-tools.sh << 'EOF'
export PATH="/opt/llm/bin:$PATH"
EOF

    systemctl daemon-reload
    systemctl enable llama-server.service

    log_info "Phase 5 complete ✓"
}

# =============================================================================
# Phase 6: Firewall
# =============================================================================
phase6_network_setup() {
    log_step "Phase 6: Network configuration"

    if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        log_info "Opening port $LLAMA_PORT in UFW..."
        ufw allow "$LLAMA_PORT/tcp"
    else
        log_warn "UFW not active, skipping firewall rule"
    fi

    log_info "Phase 6 complete ✓"
}

# =============================================================================
# Phase 7: Utility Scripts
# =============================================================================
phase7_utilities() {
    log_step "Phase 7: Installing utility scripts"

    cat > /opt/llm/bin/llm-health << 'EOF'
#!/bin/bash
source /etc/llama-server.conf 2>/dev/null || LLAMA_PORT=8080

response=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$LLAMA_PORT/health" 2>/dev/null)

if [[ "$response" == "200" ]]; then
    echo "✓ LLaMA server is healthy (port $LLAMA_PORT)"
    exit 0
else
    echo "✗ LLaMA server not responding (HTTP $response)"
    exit 1
fi
EOF
    chmod +x /opt/llm/bin/llm-health

    cat > /opt/llm/bin/llm-status << 'EOF'
#!/bin/bash
source /etc/llama-server.conf 2>/dev/null

echo "═══════════════════════════════════════════════════════"
echo "  LLaMA Server Status"
echo "═══════════════════════════════════════════════════════"
echo ""
echo "Service: $(systemctl is-active llama-server 2>/dev/null || echo 'unknown')"
echo "Model:   ${MODEL_FILE:-unknown}"
echo "Port:    ${LLAMA_PORT:-8080}"
echo "Context: ${CONTEXT_SIZE:-32768} tokens"
echo ""
echo "Memory:"
free -h | grep -E "^Mem:"
echo ""
echo "GPU:"
nvidia-smi --query-gpu=name,memory.used,memory.total,utilization.gpu --format=csv,noheader 2>/dev/null || echo "nvidia-smi not available"
echo ""
echo "Container:"
docker ps --filter name=llama-server-container --format "{{.Status}}" 2>/dev/null || echo "not running"
echo ""
echo "Health:"
/opt/llm/bin/llm-health 2>/dev/null || echo "Server not running"
echo ""
echo "Recent logs:"
journalctl -u llama-server --no-pager -n 5 2>/dev/null || echo "No logs yet"
echo ""
echo "═══════════════════════════════════════════════════════"
EOF
    chmod +x /opt/llm/bin/llm-status

    cat > /opt/llm/bin/llm-logs << 'EOF'
#!/bin/bash
journalctl -u llama-server -f
EOF
    chmod +x /opt/llm/bin/llm-logs

    log_info "Phase 7 complete ✓"
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo ""
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║  Walker's PC LLM Server Setup                                 ║"
    echo "║  NVIDIA RTX 4060 Ti - Ubuntu/Linux Mint                       ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo ""

    check_sudo
    get_actual_user

    echo "User: $ACTUAL_USER"
    echo "Models directory: $MODELS_DIR"
    echo ""

    phase1_system_setup
    echo ""
    phase2_user_setup
    echo ""
    phase3_container_setup
    echo ""
    phase4_model_download
    echo ""
    phase5_service_setup
    echo ""
    phase6_network_setup
    echo ""
    phase7_utilities
    echo ""

    IP_ADDR=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")

    echo ""
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║  Setup Complete!                                              ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo ""
    echo "Models installed:"
    echo "  • $SMALL_MODEL_FILE (fast, ~5GB)"
    echo "  • $MID_MODEL_FILE (thinking+content, ~8GB) [DEFAULT]"
    echo "  • $BEST_MODEL_FILE (best, ~20GB)"
    echo ""
    echo "Commands (available after re-login or 'source /etc/profile.d/llm-tools.sh'):"
    echo "  llm-status          Show server status (includes GPU info)"
    echo "  llm-health          Health check"
    echo "  llm-logs            View live logs"
    echo "  llm-switch          List/switch models"
    echo ""
    TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests"
    echo "Test scripts:"
    echo "  LLM_ENDPOINT=http://localhost:$LLAMA_PORT $TESTS_DIR/test-remote.sh localhost"
    echo "                      Test this box directly"
    echo "  $TESTS_DIR/test-remote.sh    Test from anywhere (hostname as arg)"
    echo ""
    echo "Service control:"
    echo "  sudo systemctl start llama-server"
    echo "  sudo systemctl stop llama-server"
    echo "  sudo systemctl restart llama-server"
    echo ""

    source /etc/llama-server.conf

    echo "API endpoint:"
    echo "  http://$IP_ADDR:$LLAMA_PORT/v1/chat/completions"
    echo ""

    if [[ -n "${LLAMA_API_KEY:-}" ]]; then
        echo "API key:"
        echo "  $LLAMA_API_KEY"
        echo ""
        echo "  Clients must send: -H 'Authorization: Bearer <key>'"
        echo "  /health and /models are public (no auth needed)"
        echo "  Remove LLAMA_API_KEY from /etc/llama-server.conf to disable"
        echo ""
    fi

    if [[ ! -f "$MODELS_DIR/$MODEL_FILE" ]]; then
        log_error "Model file not found: $MODELS_DIR/$MODEL_FILE"
        ls -lh "$MODELS_DIR"/*.gguf 2>/dev/null || echo "  (none)"
        exit 1
    fi

    log_info "Starting llama-server..."
    systemctl restart llama-server

    log_info "Waiting for server to come up (this can take 30-60s)..."
    for i in $(seq 1 60); do
        if curl -s -o /dev/null -w "%{http_code}" "http://localhost:$LLAMA_PORT/health" 2>/dev/null | grep -q "200"; then
            log_info "Server is healthy!"
            break
        fi
        if ! systemctl is-active --quiet llama-server; then
            log_error "llama-server service died. Diagnosing..."
            echo ""
            echo "--- systemd logs ---"
            journalctl -u llama-server --no-pager -n 20
            echo ""
            echo "--- attempting direct docker run for error output ---"
            docker run --rm --gpus all \
                -v /opt/llm/models:/models:ro \
                -e LLAMA_API_KEY="${LLAMA_API_KEY:-}" \
                "$CONTAINER_IMAGE" \
                --no-mmap \
                -ngl 999 \
                -fa on \
                -c "$CONTEXT_SIZE" \
                -m "/models/$MODEL_FILE" \
                --host 0.0.0.0 \
                --port "$LLAMA_PORT" \
                --metrics 2>&1 | head -50 || true
            echo ""
            log_error "Fix the issue above and re-run this script."
            exit 1
        fi
        sleep 1
    done
    echo ""

    # Optional: Cloudflare Tunnel setup
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    "$SCRIPT_DIR/setup-cloudflare.sh" "$LLAMA_PORT"

    echo ""
    echo "Try it out:"
    echo ""
    if [[ -n "${LLAMA_API_KEY:-}" ]]; then
        echo "  curl http://$IP_ADDR:$LLAMA_PORT/v1/chat/completions \\"
        echo "    -H 'Content-Type: application/json' \\"
        echo "    -H 'Authorization: Bearer $LLAMA_API_KEY' \\"
        echo "    -d '{\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}],\"max_tokens\":50}'"
    else
        echo "  curl http://$IP_ADDR:$LLAMA_PORT/v1/chat/completions \\"
        echo "    -H 'Content-Type: application/json' \\"
        echo "    -d '{\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}],\"max_tokens\":50}'"
    fi
    echo ""

    echo ""
    read -p "Run tests? (Y/n): " run_tests
    if [[ ! "$run_tests" =~ ^[Nn] ]]; then
        echo ""
        # test-local.sh was removed: it duplicated test-remote.sh, was wired to no
        # make target, and ended in an unconditional PASS that could not fail.
        # test-remote.sh honours LLM_ENDPOINT and fails when nothing streams.
        LLM_ENDPOINT="http://localhost:$LLAMA_PORT" \
            "$TESTS_DIR/test-remote.sh" localhost "$LLAMA_API_KEY" || true
    fi
}

main "$@"
