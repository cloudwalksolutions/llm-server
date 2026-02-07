#!/bin/bash
set -euo pipefail

# =============================================================================
# Beelink GTR9 Pro LLM Server Bootstrap Script
# AMD Ryzen AI Max+ 395 (Strix Halo) - Fedora 43
# =============================================================================

# Configuration
LLAMA_PORT="${LLAMA_PORT:-8080}"
LLAMA_HOST="${LLAMA_HOST:-0.0.0.0}"
MODELS_DIR="/opt/llm/models"
CONTEXT_SIZE="${CONTEXT_SIZE:-32768}"
CONTAINER_IMAGE="docker.io/kyuz0/amd-strix-halo-toolboxes:vulkan-radv"

# Models to download
SMALL_MODEL_REPO="Qwen/Qwen3-8B-GGUF"
SMALL_MODEL_FILE="qwen3-8b-q4_k_m.gguf"

BEST_MODEL_REPO="unsloth/DeepSeek-R1-Distill-Qwen-32B-GGUF"
BEST_MODEL_FILE="DeepSeek-R1-Distill-Qwen-32B-Q4_K_M.gguf"

DEFAULT_MODEL="$BEST_MODEL_FILE"

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
        echo "Usage: sudo ./beelink-llm-setup.sh"
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
# Phase 1: System Update and Kernel Configuration
# =============================================================================
phase1_system_setup() {
    log_step "Phase 1: System update and kernel configuration"
    
    log_info "Updating system packages..."
    dnf upgrade -y
    
    log_info "Installing required packages..."
    dnf install -y podman python3 git curl wget jq
    
    log_info "Configuring kernel parameters for 128GB unified GPU memory..."
    
    if grep -q "amdgpu.gttsize=131072" /proc/cmdline 2>/dev/null; then
        log_info "Kernel parameters already configured"
    else
        grubby --update-kernel=ALL --args='amd_iommu=off amdgpu.gttsize=131072 ttm.pages_limit=33554432'
        log_warn "Kernel parameters updated - REBOOT REQUIRED"
        touch /tmp/reboot_required
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
    
    log_info "Adding $ACTUAL_USER to video and render groups..."
    usermod -aG video "$ACTUAL_USER"
    usermod -aG render "$ACTUAL_USER"
    
    chown -R "$ACTUAL_USER:$ACTUAL_USER" /opt/llm
    
    log_info "Phase 2 complete ✓"
}

# =============================================================================
# Phase 3: Container Setup (using podman directly)
# =============================================================================
phase3_container_setup() {
    log_step "Phase 3: Container setup"

    get_actual_user

    log_info "Pulling llama.cpp container image..."
    podman pull "$CONTAINER_IMAGE"

    log_info "Testing GPU access..."
    if podman run --rm \
        --device /dev/kfd \
        --device /dev/dri \
        --group-add video \
        --security-opt seccomp=unconfined \
        "$CONTAINER_IMAGE" \
        ls /dev/dri 2>/dev/null | grep -q "render"; then
        log_info "GPU devices accessible in container ✓"
    else
        log_warn "GPU devices may not be ready yet - will work after reboot"
    fi

    log_info "Phase 3 complete ✓"
}

# =============================================================================
# Phase 4: Model Downloads
# =============================================================================
phase4_model_download() {
    log_step "Phase 4: Downloading models"
    
    get_actual_user
    
    # Install hf CLI via official installer — puts binary in /usr/local/bin
    if ! command -v hf &> /dev/null; then
        log_info "Installing Hugging Face CLI..."
        curl -fsSL https://huggingface.co/cli/install.sh | HF_CLI_BIN_DIR=/usr/local/bin sh
    else
        log_info "Hugging Face CLI already installed"
    fi

    # Small model
    SMALL_MODEL_PATH="$MODELS_DIR/$SMALL_MODEL_FILE"
    if [[ -f "$SMALL_MODEL_PATH" ]]; then
        log_info "Small model already exists: $SMALL_MODEL_FILE"
    else
        log_info "Downloading small model: $SMALL_MODEL_FILE (~5GB)..."
        hf download "$SMALL_MODEL_REPO" "$SMALL_MODEL_FILE" --local-dir "$MODELS_DIR"
        log_info "Small model downloaded ✓"
    fi

    # Best 32B model
    BEST_MODEL_PATH="$MODELS_DIR/$BEST_MODEL_FILE"
    if [[ -f "$BEST_MODEL_PATH" ]]; then
        log_info "Best model already exists: $BEST_MODEL_FILE"
    else
        log_info "Downloading best 32B model: $BEST_MODEL_FILE (~20GB)..."
        log_info "This will take a while, please be patient..."
        hf download "$BEST_MODEL_REPO" "$BEST_MODEL_FILE" --local-dir "$MODELS_DIR"
        log_info "Best model downloaded ✓"
    fi
    
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$MODELS_DIR"
    
    log_info "Phase 4 complete ✓"
    echo ""
    log_info "Downloaded models:"
    echo "  - $SMALL_MODEL_FILE (fast, for simple tasks)"
    echo "  - $BEST_MODEL_FILE (best quality, for complex reasoning)"
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
        cat > /etc/llama-server.conf << EOF
# LLaMA Server Configuration
# Edit and restart: sudo systemctl restart llama-server
# Switch models: llm-switch <model-filename>

LLAMA_PORT=$LLAMA_PORT
LLAMA_HOST=$LLAMA_HOST
CONTEXT_SIZE=$CONTEXT_SIZE
MODEL_FILE=$DEFAULT_MODEL
CONTAINER_IMAGE=$CONTAINER_IMAGE
EOF
        log_info "Created /etc/llama-server.conf"
    else
        log_info "/etc/llama-server.conf already exists, preserving"
    fi

    # Create systemd service using podman directly
    cat > /etc/systemd/system/llama-server.service << 'EOF'
[Unit]
Description=LLaMA.cpp Inference Server
After=network.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/llama-server.conf

ExecStartPre=-/usr/bin/podman rm -f llama-server-container
ExecStart=/usr/bin/podman run \
    --name llama-server-container \
    --rm \
    --device /dev/kfd \
    --device /dev/dri \
    --group-add video \
    --security-opt seccomp=unconfined \
    -v /opt/llm/models:/models:ro \
    -p ${LLAMA_PORT}:${LLAMA_PORT} \
    ${CONTAINER_IMAGE} \
    llama-server \
        --no-mmap \
        -ngl 999 \
        -fa \
        -c ${CONTEXT_SIZE} \
        -m /models/${MODEL_FILE} \
        --host 0.0.0.0 \
        --port ${LLAMA_PORT} \
        --metrics

ExecStop=/usr/bin/podman stop llama-server-container

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
# Phase 6: Firewall and Network
# =============================================================================
phase6_network_setup() {
    log_step "Phase 6: Network configuration"
    
    if systemctl is-active --quiet firewalld; then
        log_info "Opening port $LLAMA_PORT in firewall..."
        firewall-cmd --permanent --add-port="$LLAMA_PORT/tcp"
        firewall-cmd --reload
    else
        log_warn "firewalld not running, skipping"
    fi
    
    log_info "Phase 6 complete ✓"
}

# =============================================================================
# Phase 7: Utility Scripts
# =============================================================================
phase7_utilities() {
    log_step "Phase 7: Installing utility scripts"
    
    # Health check
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
    
    # Status
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
echo "Container:"
podman ps --filter name=llama-server-container --format "{{.Status}}" 2>/dev/null || echo "not running"
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
    
    # Test API
    cat > /opt/llm/bin/llm-test << 'EOF'
#!/bin/bash
source /etc/llama-server.conf 2>/dev/null || LLAMA_PORT=8080

echo "Testing LLaMA server API..."
echo ""

result=$(curl -s "http://localhost:$LLAMA_PORT/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d '{
        "messages": [{"role": "user", "content": "Say hello in exactly 5 words."}],
        "max_tokens": 50,
        "temperature": 0.7
    }' 2>/dev/null)

if command -v jq &>/dev/null; then
    echo "$result" | jq -r '.choices[0].message.content // .'
else
    echo "$result"
fi

echo ""
EOF
    chmod +x /opt/llm/bin/llm-test
    
    # Logs
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
    echo "║  Beelink GTR9 Pro LLM Server Setup                            ║"
    echo "║  AMD Ryzen AI Max+ 395 (Strix Halo) - 128GB                   ║"
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
    
    # Get IP for display
    IP_ADDR=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")
    
    echo ""
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║  Setup Complete!                                              ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo ""
    echo "Models installed:"
    echo "  • $SMALL_MODEL_FILE (fast, ~5GB)"
    echo "  • $BEST_MODEL_FILE (best, ~20GB) [DEFAULT]"
    echo ""
    echo "Commands (available after re-login or 'source /etc/profile.d/llm-tools.sh'):"
    echo "  llm-status          Show server status"
    echo "  llm-health          Health check"
    echo "  llm-test            Test the API"
    echo "  llm-logs            View live logs"
    echo "  llm-switch          List/switch models"
    echo ""
    echo "Service control:"
    echo "  sudo systemctl start llama-server"
    echo "  sudo systemctl stop llama-server"
    echo "  sudo systemctl restart llama-server"
    echo ""
    echo "API endpoint:"
    echo "  http://$IP_ADDR:$LLAMA_PORT/v1/chat/completions"
    echo ""
    
    if [[ -f /tmp/reboot_required ]]; then
        echo "╔═══════════════════════════════════════════════════════════════╗"
        echo "║  ⚠️  REBOOT REQUIRED                                          ║"
        echo "╚═══════════════════════════════════════════════════════════════╝"
        echo ""
        echo "Kernel parameters were updated for GPU memory access."
        echo ""
        echo "Run now:"
        echo "  sudo reboot"
        echo ""
        echo "After reboot, the server will start automatically."
        echo "Check status with: llm-status"
        echo ""
        rm -f /tmp/reboot_required
    else
        log_info "Starting llama-server..."
        systemctl restart llama-server

        echo "Server is starting up (may take 30-60 seconds to load model)..."
        echo "Check status with: llm-status"
        echo ""
    fi

    # Optional: Cloudflare Tunnel setup
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    "$SCRIPT_DIR/setup-cloudflare.sh" "$LLAMA_PORT"
}

main "$@"
