# Ollama Server

This guide provides step-by-step instructions on how to set up an Ollama server on Ubuntu,
allowing you to run and serve large language models (LLMs) like Llama 3, Mistral, and more.
The server will be accessible both locally and remotely, with optional exposure via Cloudflare Tunnel.

## Prerequisites

* Ubuntu 22.04 LTS or later with sudo access
* 8–16 GB RAM (more if running larger models)
* SSH access to the server
* (Optional) Cloudflare account and domain for Tunnel exposure

## 1. Install Ollama

```bash
curl -fsSL https://ollama.com/install.sh | sh
ollama --version
```

## 2. Configure systemd to Listen Externally

By default, Ollama binds to 127.0.0.1. To bind on all interfaces:

```bash
sudo systemctl edit ollama.service
```

Add under `[Service]`:

```ini
Environment="OLLAMA_HOST=http://0.0.0.0:11434"
```

Reload and restart:

```bash
sudo systemctl daemon-reload
sudo systemctl restart ollama.service
```

Verify listener:

```bash
sudo ss -lnpt | grep 11434
# should show 0.0.0.0:11434
```

## 3. Open the Firewall

Allow external TCP traffic on port 11434:

```bash
sudo ufw allow 11434/tcp
sudo ufw reload
```

## 4. (Optional) Expose via Cloudflare Tunnel

### 4.1 Install `cloudflared`

```bash
wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
sudo apt install ./cloudflared-linux-amd64.deb
```

### 4.2 Authenticate & Create Tunnel

```bash
cloudflared tunnel login
cloudflared tunnel create ollama-tunnel
```

### 4.3 Configure Tunnel

Create `/etc/cloudflared/config.yml`:

```yaml
tunnel: <TUNNEL-UUID>
credentials-file: /etc/cloudflared/<TUNNEL-UUID>.json
ingress:
  - hostname: ollama.example.com
    service: http://localhost:11434
  - service: http_status:404
```

### 4.4 DNS Mapping

In Cloudflare DNS, add a CNAME:

* Name: `ollama`
* Target: `<TUNNEL-UUID>.cfargotunnel.com`
* Proxy: Proxied (orange cloud)

### 4.5 Run Tunnel as Service

```bash
sudo cloudflared service install
sudo systemctl enable --now cloudflared
```

## 5. Test Your Server

* **Local**:

  ```bash
  curl http://localhost:11434/v1/models
  ```
* **Remote (Cloudflare)**:

  ```bash
  curl https://ollama.example.com/v1/models
  ```

Your Ollama server is now installed, bound to all interfaces, firewall-open, and optionally exposed globally via Cloudflare Tunnel. Enjoy serving LLMs!


