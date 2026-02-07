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
sudo systemctl enable ${OLLAMA_SERVICE}
sudo systemctl restart ${OLLAMA_SERVICE}

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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$SCRIPT_DIR/setup-cloudflare.sh" 11434

echo "[*] Setup complete. Ollama is running on port 11434."
