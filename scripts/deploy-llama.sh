#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

$DRY_RUN && echo -e "${YELLOW}DRY RUN MODE${NC}\n"

# Load configuration
load_config || exit 1

TIMESTAMP=$(date +"%Y%m%d-%H%M%S")

echo -e "${CYAN}[1/8]${NC} Config loaded: $PARALLEL_SLOTS slots, $BATCH_SIZE/$UBATCH_SIZE batch, $THREADS_GEN/$THREADS_BATCH/$THREADS_HTTP threads"
echo -e "${CYAN}[2/8]${NC} Connecting to ${REMOTE_USER}@${REMOTE_HOST}..."

test_ssh || { echo -e "${RED}Connection failed${NC}"; exit 1; }

if $DRY_RUN; then
    echo -e "${CYAN}[3/8]${NC} ${YELLOW}Would backup:${NC} /etc/llama-server.conf.backup.$TIMESTAMP"
    echo -e "${CYAN}[4/8]${NC} ${YELLOW}Would add to /etc/llama-server.conf:${NC}"
    echo "  PARALLEL_SLOTS=$PARALLEL_SLOTS BATCH_SIZE=$BATCH_SIZE UBATCH_SIZE=$UBATCH_SIZE"
    echo "  THREADS_GEN=$THREADS_GEN THREADS_BATCH=$THREADS_BATCH THREADS_HTTP=$THREADS_HTTP CACHE_REUSE=$CACHE_REUSE"
    echo -e "${CYAN}[5/8]${NC} ${YELLOW}Would update systemd service with llama-server flags${NC}"
    echo -e "${CYAN}[6/8]${NC} ${YELLOW}Would reload systemd${NC}"
    echo -e "${CYAN}[7/8]${NC} ${YELLOW}Would restart llama-server${NC}"
    echo -e "${CYAN}[8/8]${NC} ${YELLOW}Would verify health${NC}"
    echo -e "\n${YELLOW}DRY RUN COMPLETE - Run 'make deploy' to apply${NC}"
    exit 0
fi

echo -e "${CYAN}[3/8]${NC} Creating backups..."
remote_exec_sudo "cp /etc/llama-server.conf /etc/llama-server.conf.backup.$TIMESTAMP 2>/dev/null || true"
remote_exec_sudo "cp /etc/systemd/system/llama-server.service /etc/systemd/system/llama-server.service.backup.$TIMESTAMP 2>/dev/null || true"

echo -e "${CYAN}[4/8]${NC} Updating /etc/llama-server.conf..."

# Get current base settings from remote
REMOTE_LLAMA_PORT=$(remote_exec "grep '^LLAMA_PORT=' /etc/llama-server.conf 2>/dev/null | cut -d= -f2" || echo "8080")
REMOTE_LLAMA_HOST=$(remote_exec "grep '^LLAMA_HOST=' /etc/llama-server.conf 2>/dev/null | cut -d= -f2" || echo "0.0.0.0")
REMOTE_MODEL_FILE=$(remote_exec "grep '^MODEL_FILE=' /etc/llama-server.conf 2>/dev/null | cut -d= -f2" || echo "Qwen3-8B-Q4_K_M.gguf")
REMOTE_CONTAINER_IMAGE=$(remote_exec "grep '^CONTAINER_IMAGE=' /etc/llama-server.conf 2>/dev/null | cut -d= -f2" || echo "docker.io/kyuz0/amd-strix-halo-toolboxes:vulkan-radv")
REMOTE_LLAMA_API_KEY=$(remote_exec "grep '^LLAMA_API_KEY=' /etc/llama-server.conf 2>/dev/null | cut -d= -f2" || echo "")

# Create complete config file locally
cat > /tmp/llama-server.conf <<EOF
# LLaMA Server Configuration
# Edit and restart: sudo systemctl restart llama-server
# Deployed: $(date +"%Y-%m-%d %H:%M:%S")

# Base configuration
LLAMA_PORT=$REMOTE_LLAMA_PORT
LLAMA_HOST=$REMOTE_LLAMA_HOST
CONTEXT_SIZE=$CONTEXT_SIZE
MODEL_FILE=$REMOTE_MODEL_FILE
CONTAINER_IMAGE=$REMOTE_CONTAINER_IMAGE

# API key for bearer-token auth
LLAMA_API_KEY=$REMOTE_LLAMA_API_KEY

# Optimization parameters
PARALLEL_SLOTS=$PARALLEL_SLOTS
BATCH_SIZE=$BATCH_SIZE
UBATCH_SIZE=$UBATCH_SIZE
THREADS_GEN=$THREADS_GEN
THREADS_BATCH=$THREADS_BATCH
THREADS_HTTP=$THREADS_HTTP
CACHE_REUSE=$CACHE_REUSE
EOF

# Copy to remote
if [[ "$SSH_AUTH" == "password" ]]; then
    sshpass -p "$SSH_PASS" scp -o StrictHostKeyChecking=no /tmp/llama-server.conf "$REMOTE_USER@$REMOTE_HOST:/tmp/"
else
    scp -i "$SSH_KEY" -o StrictHostKeyChecking=no /tmp/llama-server.conf "$REMOTE_USER@$REMOTE_HOST:/tmp/"
fi

# Replace config file
remote_exec_sudo "mv /tmp/llama-server.conf /etc/llama-server.conf"
remote_exec_sudo "chmod 644 /etc/llama-server.conf"

echo -e "${CYAN}[5/8]${NC} Updating systemd service..."
remote_exec_sudo "systemctl unmask llama-server 2>/dev/null || true"

# Create temporary service file locally
cat > /tmp/llama-server.service <<'EOF'
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
    -e LLAMA_API_KEY=${LLAMA_API_KEY} \
    ${CONTAINER_IMAGE} \
    llama-server \
        --no-mmap \
        -ngl 999 \
        -fa on \
        -c ${CONTEXT_SIZE} \
        -np ${PARALLEL_SLOTS} \
        -b ${BATCH_SIZE} \
        -ub ${UBATCH_SIZE} \
        --cont-batching \
        --cache-prompt \
        --cache-reuse ${CACHE_REUSE} \
        -t ${THREADS_GEN} \
        -tb ${THREADS_BATCH} \
        --threads-http ${THREADS_HTTP} \
        --cache-type-k f16 \
        --cache-type-v f16 \
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

# Copy to remote using SCP
if [[ "$SSH_AUTH" == "password" ]]; then
    sshpass -p "$SSH_PASS" scp -o StrictHostKeyChecking=no /tmp/llama-server.service "$REMOTE_USER@$REMOTE_HOST:/tmp/"
else
    scp -i "$SSH_KEY" -o StrictHostKeyChecking=no /tmp/llama-server.service "$REMOTE_USER@$REMOTE_HOST:/tmp/"
fi

# Move to systemd directory with sudo
remote_exec_sudo "mv /tmp/llama-server.service /etc/systemd/system/llama-server.service"
remote_exec_sudo "chmod 644 /etc/systemd/system/llama-server.service"

echo -e "${CYAN}[6/8]${NC} Reloading systemd..."
remote_exec_sudo "systemctl daemon-reload"
remote_exec_sudo "systemctl enable llama-server"

echo -e "${CYAN}[7/8]${NC} Restarting llama-server..."
remote_exec_sudo "systemctl restart llama-server"

echo -e "${CYAN}[8/8]${NC} Waiting for health check..."
for i in {1..60}; do
    if remote_exec "curl -sf http://localhost:8080/health > /dev/null 2>&1"; then
        echo -e "${GREEN}✓ Deployment complete!${NC}\n"
        echo -e "${GREEN}Applied: ${PARALLEL_SLOTS} slots, ${BATCH_SIZE}/${UBATCH_SIZE} batch, ${THREADS_GEN}/${THREADS_BATCH}/${THREADS_HTTP} threads${NC}"
        echo -e "\nNext: ${BLUE}make status${NC} | ${BLUE}make benchmark${NC} | ${BLUE}make logs${NC}"
        exit 0
    fi
    sleep 1
done

echo -e "${RED}Health check timeout. Check logs: make logs${NC}"
exit 1
