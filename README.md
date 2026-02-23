# LLM Server

Automated setup scripts for running local LLM inference servers with optional Cloudflare Tunnel exposure.

Hi Sunny :)

Three backends are supported:

| Backend | Script | OS | Port | Use case |
|---------|--------|----|------|----------|
| **llama.cpp (AMD)** | `scripts/install-llama.sh` | Fedora | 8080 | AMD GPU (Strix Halo), Vulkan acceleration |
| **llama.cpp (NVIDIA)** | `scripts/install-llama-nvidia.sh` | Ubuntu/Mint | 8080 | NVIDIA GPU, CUDA acceleration |
| **Ollama** | `scripts/install-ollama.sh` | Ubuntu | 11434 | Quick setup, broad model support |

Both llama.cpp scripts offer optional Cloudflare Tunnel setup at the end via a shared `scripts/setup-cloudflare.sh` script.

## Quick Start

### llama.cpp (Fedora / AMD Strix Halo)

```bash
sudo ./scripts/install-llama.sh
```

Sets up kernel params for 128GB unified GPU memory, pulls a Vulkan-accelerated llama.cpp container, downloads models (Qwen3-8B + DeepSeek-R1-32B), creates a systemd service, and optionally sets up a Cloudflare Tunnel.

### llama.cpp (Ubuntu/Mint / NVIDIA)

```bash
sudo ./scripts/install-llama-nvidia.sh
```

Installs nvidia-container-toolkit, pulls a CUDA-accelerated llama.cpp container, downloads models, creates a systemd service on port 8080, and optionally sets up a Cloudflare Tunnel.

### Ollama (Ubuntu)

```bash
sudo ./scripts/install-ollama.sh
```

Installs Ollama, configures systemd to bind on `0.0.0.0:11434`, opens the firewall, and optionally sets up a Cloudflare Tunnel.

After install, useful commands are available:

```
llm-status    # Show server status
llm-health    # Health check
llm-logs      # View live logs
llm-switch    # List/switch models
```

## Remote Management

After running an install script, use the `make` targets from this repo to manage the server remotely:

```bash
make deploy      # Push config/llama.yaml performance settings to the server
make deploy-dry  # Preview deployment without applying
make status      # Show server status
make logs        # View recent logs
make test        # Run API tests
make benchmark   # Run k6 load tests
make ssh         # SSH into the server
```

Configuration lives in `config/llama.yaml` — edit `remote.host` and `remote.user` to point at your target machine.

## Cloudflare Tunnel (Optional)

Both llama.cpp install scripts call `scripts/setup-cloudflare.sh` at the end. It will prompt you interactively:

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
sudo ./scripts/setup-cloudflare.sh <port>
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
