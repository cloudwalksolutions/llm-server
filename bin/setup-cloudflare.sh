#!/usr/bin/env bash
# Shared Cloudflare Tunnel setup — called by install-ollama.sh and install-llama.sh
# Usage: sudo ./setup-cloudflare.sh <local-service-port>

set -euo pipefail

SERVICE_PORT="${1:?Usage: $0 <local-service-port>}"
CF_CONFIG_DIR="/etc/cloudflared"
CF_CONFIG="$CF_CONFIG_DIR/config.yml"

echo ""
read -p "Do you want to setup Cloudflare Tunnel? (y/N): " cf_ans
if [[ ! "$cf_ans" =~ ^[Yy] ]]; then
  echo "[*] Skipping Cloudflare Tunnel setup"
  exit 0
fi

read -p "Enter Tunnel name (e.g. llm-server): " CF_TUNNEL_NAME
read -p "Enter hostname for Tunnel (e.g. llm.example.com): " CF_HOSTNAME

# Install cloudflared if missing
if ! command -v cloudflared &> /dev/null; then
  echo "[*] Installing cloudflared..."
  if command -v apt-get &> /dev/null; then
    wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
    sudo apt-get update && sudo apt-get install -y ./cloudflared-linux-amd64.deb
    rm -f cloudflared-linux-amd64.deb
  elif command -v dnf &> /dev/null; then
    sudo dnf install -y cloudflared || {
      wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-x86_64.rpm
      sudo dnf install -y ./cloudflared-linux-x86_64.rpm
      rm -f cloudflared-linux-x86_64.rpm
    }
  else
    echo "[!] Unsupported package manager — install cloudflared manually"
    exit 1
  fi
fi

# Authenticate if no cert exists
if [[ ! -f /root/.cloudflared/cert.pem ]]; then
  echo "[*] Authenticating cloudflared (browser will open)..."
  cloudflared tunnel login
fi

# Create tunnel if it doesn't exist
if cloudflared tunnel list | grep -qw "$CF_TUNNEL_NAME"; then
  echo "[*] Tunnel '$CF_TUNNEL_NAME' already exists"
else
  echo "[*] Creating tunnel '$CF_TUNNEL_NAME'..."
  cloudflared tunnel create "$CF_TUNNEL_NAME"
fi

# Get tunnel ID from the credentials file that tunnel create wrote
TUNNEL_ID=$(cloudflared tunnel list --output json | jq -r ".[] | select(.name==\"$CF_TUNNEL_NAME\") | .id")
CRED_FILE="/root/.cloudflared/${TUNNEL_ID}.json"

if [[ -z "$TUNNEL_ID" || ! -f "$CRED_FILE" ]]; then
  echo "[!] Could not find tunnel ID or credentials file"
  echo "    Run 'cloudflared tunnel list' to debug"
  exit 1
fi

echo "[*] Tunnel ID: $TUNNEL_ID"
echo "[*] Credentials: $CRED_FILE"

# Write config
echo "[*] Writing $CF_CONFIG..."
sudo mkdir -p "$CF_CONFIG_DIR"

# Copy credentials to /etc/cloudflared so the service can find them
sudo cp "$CRED_FILE" "$CF_CONFIG_DIR/"

sudo tee "$CF_CONFIG" > /dev/null <<EOF
tunnel: $TUNNEL_ID
credentials-file: $CF_CONFIG_DIR/${TUNNEL_ID}.json
ingress:
  - hostname: $CF_HOSTNAME
    service: http://localhost:$SERVICE_PORT
  - service: http_status:404
EOF

# Add DNS route
echo "[*] Adding DNS route: $CF_HOSTNAME -> $CF_TUNNEL_NAME..."
cloudflared tunnel route dns "$CF_TUNNEL_NAME" "$CF_HOSTNAME" || true

# Install and start systemd service
echo "[*] Installing cloudflared service..."
# Remove existing service if present (idempotent reinstall)
sudo cloudflared service uninstall 2>/dev/null || true
sudo cloudflared --config "$CF_CONFIG" service install
sudo systemctl enable --now cloudflared

echo "[*] Verifying tunnel is running..."
sleep 2
if systemctl is-active --quiet cloudflared; then
  echo "[*] Cloudflare Tunnel is running"
else
  echo "[!] Cloudflare Tunnel failed to start — check: journalctl -u cloudflared"
fi

echo "[*] Cloudflare Tunnel setup complete"
