#!/usr/bin/env bash
# Automated setup for Ollama LLM server on Ubuntu with optional Cloudflare Tunnel
# Usage: sudo ./setup-ollama-server.sh

set -euo pipefail

echo "[*] Starting Ollama server setup..."

# 1. Install Ollama
if ! command -v ollama &> /dev/null; then
  echo "[*] Installing Ollama..."
  curl -fsSL https://ollama.com/install.sh | sh
else
  echo "[*] Ollama is already installed"
fi

# 2. Configure systemd to listen on all interfaces
echo "[*] Configuring Ollama to bind on 0.0.0.0:11434..."
OLLAMA_SERVICE="ollama.service"
sudo mkdir -p /etc/systemd/system/${OLLAMA_SERVICE}.d
sudo tee /etc/systemd/system/${OLLAMA_SERVICE}.d/override.conf > /dev/null <<EOF
[Service]
Environment="OLLAMA_HOST=http://0.0.0.0:11434"
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now ${OLLAMA_SERVICE}

echo "[*] Ollama service configured and restarted"

# 3. Open firewall
echo "[*] Opening firewall port 11434..."
if command -v ufw &> /dev/null; then
  sudo ufw allow 11434/tcp
  sudo ufw reload
  echo "[*] Firewall updated"
else
  echo "[*] UFW not installed; skipping firewall configuration"
fi

# 4. Disable power button to avoid accidental shutdown
echo "[*] Disabling power button action..."
sudo sed -i 's/^#\?HandlePowerKey=.*/HandlePowerKey=ignore/' /etc/systemd/logind.conf || \
  echo 'HandlePowerKey=ignore' | sudo tee -a /etc/systemd/logind.conf > /dev/null
sudo systemctl restart systemd-logind

echo "[*] Power button disabled"

# 5. Optional: Cloudflare Tunnel setup
echo ""
read -p "Do you want to setup Cloudflare Tunnel? (y/N): " cf_ans
if [[ "$cf_ans" =~ ^[Yy] ]]; then
  # Prompt for names
  read -p "Enter Tunnel name (e.g. ollama-tunnel): " CF_TUNNEL_NAME
  read -p "Enter hostname for Tunnel (e.g. ollama.example.com): " CF_HOSTNAME

  echo "[*] Installing cloudflared if missing..."
  if ! command -v cloudflared &> /dev/null; then
    wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
    sudo apt-get update && sudo apt-get install -y ./cloudflared-linux-amd64.deb
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
      service: http://localhost:11434
    - service: http_status:404
EOF

  echo "[*] Please add DNS CNAME: $CF_HOSTNAME -> $TUNNEL_ID.cfargotunnel.com"

  echo "[*] Installing cloudflared service..."
  sudo cloudflared service install
  sudo systemctl enable --now cloudflared
  echo "[*] Cloudflare Tunnel setup complete"
else
  echo "[*] Skipping Cloudflare Tunnel setup"
fi

echo "[*] Setup complete. Ollama is running on port 11434."
