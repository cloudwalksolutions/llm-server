#!/usr/bin/env bash
# Shared Cloudflare Tunnel setup — called by install-ollama.sh and install-llama.sh
# Usage: sudo ./setup-cloudflare.sh <local-service-port>

set -euo pipefail

SERVICE_PORT="${1:?Usage: $0 <local-service-port>}"

echo ""
read -p "Do you want to setup Cloudflare Tunnel? (y/N): " cf_ans
if [[ ! "$cf_ans" =~ ^[Yy] ]]; then
  echo "[*] Skipping Cloudflare Tunnel setup"
  exit 0
fi

read -p "Enter Tunnel name (e.g. ollama-tunnel): " CF_TUNNEL_NAME
read -p "Enter hostname for Tunnel (e.g. ollama.example.com): " CF_HOSTNAME

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

echo "[*] Authenticating cloudflared..."
cloudflared tunnel login

echo "[*] Creating or retrieving Tunnel '$CF_TUNNEL_NAME'..."
if cloudflared tunnel list | grep -qw "$CF_TUNNEL_NAME"; then
  echo "[*] Tunnel exists; fetching details..."
  TUNNEL_INFO=$(cloudflared tunnel info "$CF_TUNNEL_NAME")
else
  TUNNEL_INFO=$(cloudflared tunnel create "$CF_TUNNEL_NAME")
fi

# Parse Tunnel ID and credentials file
TUNNEL_ID=$(echo "$TUNNEL_INFO" | grep -Po 'Tunnel ID: \K[^ ]+')
CRED_FILE=$(echo "$TUNNEL_INFO" | grep -Po 'Credentials File: \K.*')

echo "[*] Tunnel ID: $TUNNEL_ID"
echo "[*] Credentials: $CRED_FILE"

echo "[*] Writing Cloudflare Tunnel config..."
sudo mkdir -p /etc/cloudflared
sudo tee /etc/cloudflared/config.yml > /dev/null <<EOF
tunnel: $TUNNEL_ID
credentials-file: $CRED_FILE
ingress:
  - hostname: $CF_HOSTNAME
    service: http://localhost:$SERVICE_PORT
  - service: http_status:404
EOF

echo "[*] Please add DNS CNAME: $CF_HOSTNAME -> $TUNNEL_ID.cfargotunnel.com"

echo "[*] Installing cloudflared service..."
sudo cloudflared service install
sudo systemctl enable --now cloudflared
echo "[*] Cloudflare Tunnel setup complete"
