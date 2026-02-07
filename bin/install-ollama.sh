#!/usr/bin/env bash
# Automated setup for Ollama LLM server on Ubuntu with optional Cloudflare Tunnel
# Usage: sudo ./setup-ollama-server.sh

set -euo pipefail

echo "[*] Starting Ollama server setup..."

# 0. Ensure jq is available (needed by setup-cloudflare.sh)
if ! command -v jq &> /dev/null; then
  echo "[*] Installing jq..."
  sudo apt-get update && sudo apt-get install -y jq byobu
fi

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

IP_ADDR=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")

echo "[*] Setup complete. Ollama is running on port 11434."
echo ""
echo "Try it out:"
echo ""
echo "  curl http://$IP_ADDR:11434/v1/chat/completions \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"model\":\"llama3\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}],\"max_tokens\":50}'"
echo ""

# If Cloudflare was configured, show that too
if [[ -f /etc/cloudflared/config.yml ]]; then
  CF_HOST=$(grep 'hostname:' /etc/cloudflared/config.yml | head -1 | awk '{print $3}')
  if [[ -n "$CF_HOST" ]]; then
    echo "Via Cloudflare Tunnel:"
    echo ""
    echo "  curl https://$CF_HOST/v1/chat/completions \\"
    echo "    -H 'Content-Type: application/json' \\"
    echo "    -d '{\"model\":\"llama3\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}],\"max_tokens\":50}'"
    echo ""
  fi
fi
