# LLM Server

Automated setup scripts for running local LLM inference servers with optional Cloudflare Tunnel exposure.

Two backends are supported:

| Backend | Script | OS | Port | Use case |
|---------|--------|----|------|----------|
| **Ollama** | `bin/install-ollama.sh` | Ubuntu | 11434 | Quick setup, broad model support |
| **llama.cpp** | `bin/install-llama.sh` | Fedora | 8080 | AMD GPU (Strix Halo), Vulkan acceleration |

Both scripts offer optional Cloudflare Tunnel setup at the end via a shared `bin/setup-cloudflare.sh` script.

## Quick Start

### Ollama (Ubuntu)

```bash
sudo ./bin/install-ollama.sh
```

Installs Ollama, configures systemd to bind on `0.0.0.0:11434`, opens the firewall, and optionally sets up a Cloudflare Tunnel.

### llama.cpp (Fedora / AMD Strix Halo)

```bash
sudo ./bin/install-llama.sh
```

Sets up kernel params for 128GB unified GPU memory, pulls a Vulkan-accelerated llama.cpp container, downloads models (Qwen3-8B + DeepSeek-R1-32B), creates a systemd service, and optionally sets up a Cloudflare Tunnel.

After install, useful commands are available:

```
llm-status    # Show server status
llm-health    # Health check
llm-test      # Test the API
llm-logs      # View live logs
llm-switch    # List/switch models
```

## Cloudflare Tunnel (Optional)

Both install scripts call `bin/setup-cloudflare.sh` at the end. It will prompt you interactively:

```
Do you want to setup Cloudflare Tunnel? (y/N):
```

If you accept, it will:

1. Install `cloudflared` (detects apt vs dnf)
2. Authenticate with Cloudflare
3. Create or reuse a named tunnel
4. Write `/etc/cloudflared/config.yml` pointing to the local service port
5. Install and enable the `cloudflared` systemd service

You can also run it standalone:

```bash
sudo ./bin/setup-cloudflare.sh <port>
```

## Testing

```bash
# Ollama
curl http://localhost:11434/v1/models

# llama.cpp
curl http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"messages": [{"role": "user", "content": "Hello"}], "max_tokens": 50}'

# Via Cloudflare Tunnel
curl https://your-hostname.example.com/v1/models
```
