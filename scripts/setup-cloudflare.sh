#!/usr/bin/env bash
# Shared Cloudflare Tunnel setup — called by install-ollama.sh and install-llama.sh
# Usage: sudo ./setup-cloudflare.sh <local-service-port>
#        sudo ./setup-cloudflare.sh --reconfigure

set -euo pipefail

CF_CONFIG_DIR="/etc/cloudflared"
CF_CONFIG="$CF_CONFIG_DIR/config.yml"

# Validate hostname — Cloudflare Universal SSL only covers *.domain.tld (one level)
# Sub-subdomains like a.b.domain.tld will fail TLS handshake
validate_hostname() {
  local host="$1"
  # Count dots: a.b.com = 2 dots (ok), a.b.c.com = 3 dots (sub-subdomain)
  local dot_count
  dot_count=$(echo "$host" | tr -cd '.' | wc -c)
  if [[ "$dot_count" -ge 3 ]]; then
    local suggested
    # Get everything before the base domain (last two parts) and convert dots to hyphens
    local base_domain
    base_domain=$(echo "$host" | rev | cut -d. -f1-2 | rev)
    local prefix
    prefix=$(echo "$host" | rev | cut -d. -f3- | rev | tr '.' '-')
    suggested="${prefix}.${base_domain}"
    echo ""
    echo "[!] WARNING: '$host' is a sub-subdomain."
    echo "    Cloudflare Universal SSL only covers *.$(echo "$host" | rev | cut -d. -f1-2 | rev)"
    echo "    HTTPS will fail with a TLS handshake error."
    echo ""
    read -p "    Use '$suggested' instead? (Y/n): " fix_ans
    if [[ ! "$fix_ans" =~ ^[Nn] ]]; then
      CF_HOSTNAME="$suggested"
      echo "[*] Using: $CF_HOSTNAME"
    else
      echo "[*] Keeping: $host (HTTPS may not work without Advanced Certificate Manager)"
    fi
  fi
}

# Handle --reconfigure mode
if [[ "${1:-}" == "--reconfigure" ]]; then
  if [[ ! -f "$CF_CONFIG" ]]; then
    echo "[!] No existing tunnel config found at $CF_CONFIG"
    echo "    Run the install script first to set up a tunnel."
    exit 1
  fi

  CF_HOSTNAME=$(grep 'hostname:' "$CF_CONFIG" | head -1 | awk '{print $3}')
  EXISTING_TUNNEL_ID=$(grep '^tunnel:' "$CF_CONFIG" | awk '{print $2}')
  CF_TUNNEL_NAME=$(cloudflared tunnel list --output json 2>/dev/null | jq -r ".[] | select(.id==\"$EXISTING_TUNNEL_ID\") | .name")
  SERVICE_PORT=$(grep 'service:' "$CF_CONFIG" | head -1 | grep -oP 'localhost:\K[0-9]+')

  echo "[*] Current tunnel: $CF_TUNNEL_NAME"
  echo "[*] Current hostname: $CF_HOSTNAME"
  echo "[*] Service port: $SERVICE_PORT"
  echo ""

  read -p "Enter new hostname (leave empty to keep '$CF_HOSTNAME'): " NEW_HOSTNAME
  if [[ -z "$NEW_HOSTNAME" ]]; then
    echo "[*] No changes."
    exit 0
  fi

  CF_HOSTNAME="$NEW_HOSTNAME"
  validate_hostname "$CF_HOSTNAME"

  echo "[*] Updating config: $CF_HOSTNAME..."
  TUNNEL_ID="$EXISTING_TUNNEL_ID"
  CRED_FILE="$CF_CONFIG_DIR/${TUNNEL_ID}.json"

  # Write updated config
  sudo tee "$CF_CONFIG" > /dev/null <<EOF
tunnel: $TUNNEL_ID
credentials-file: $CRED_FILE
ingress:
  - hostname: $CF_HOSTNAME
    service: http://localhost:$SERVICE_PORT
  - service: http_status:404
EOF

  # Update DNS route
  echo "[*] Adding DNS route: $CF_HOSTNAME -> $CF_TUNNEL_NAME..."
  cloudflared tunnel route dns "$CF_TUNNEL_NAME" "$CF_HOSTNAME" || true

  # Restart service
  echo "[*] Restarting cloudflared..."
  sudo systemctl restart cloudflared

  sleep 2
  if systemctl is-active --quiet cloudflared; then
    echo "[*] Cloudflare Tunnel is running"
  else
    echo "[!] Cloudflare Tunnel failed to start — check: journalctl -u cloudflared"
    exit 1
  fi

  echo ""
  echo "[*] Reconfiguration complete: https://$CF_HOSTNAME"
  echo ""
  echo "    NOTE: Delete the old DNS record in the Cloudflare dashboard"
  echo "    if it's no longer needed."
  exit 0
fi

SERVICE_PORT="${1:?Usage: $0 <local-service-port>  or  $0 --reconfigure}"

echo ""
read -p "Do you want to setup Cloudflare Tunnel? (y/N): " cf_ans
if [[ ! "$cf_ans" =~ ^[Yy] ]]; then
  echo "[*] Skipping Cloudflare Tunnel setup"
  exit 0
fi

# Reuse existing config if available — don't ask again
if [[ -f "$CF_CONFIG" ]]; then
  CF_HOSTNAME=$(grep 'hostname:' "$CF_CONFIG" | head -1 | awk '{print $3}')
  EXISTING_TUNNEL_ID=$(grep '^tunnel:' "$CF_CONFIG" | awk '{print $2}')
  CF_TUNNEL_NAME=$(cloudflared tunnel list --output json 2>/dev/null | jq -r ".[] | select(.id==\"$EXISTING_TUNNEL_ID\") | .name")
  echo "[*] Using existing config: tunnel=$CF_TUNNEL_NAME hostname=$CF_HOSTNAME"
else
  read -p "Enter Tunnel name (e.g. llm-server): " CF_TUNNEL_NAME
  read -p "Enter hostname for Tunnel (e.g. llm.example.com): " CF_HOSTNAME
  validate_hostname "$CF_HOSTNAME"
fi

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
