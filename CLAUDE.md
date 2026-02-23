# LLM Server — Project Guide

## What This Is

Tooling for deploying and managing llama-server (llama.cpp) inference servers. Scripts install the server on target machines; `config/llama.yaml` + `make` commands handle remote config deployment and management.

## Server Targets

To switch deploy target, update `remote.host` and `remote.user` in `config/llama.yaml` and tune the performance parameters to match that machine.

## Key Files

- `config/llama.yaml` — active deploy target and performance tuning (not in git)
- `config/llama.example.yaml` — template
- `scripts/deploy-llama.sh` — SSH into target, write `/etc/llama-server.conf`, restart service
- `scripts/install-llama.sh` — bootstrap for AMD Strix Halo / Fedora
- `scripts/install-llama-nvidia.sh` — bootstrap for NVIDIA / Ubuntu/Mint
- `scripts/lib/common.sh` — shared SSH helpers (`remote_exec`, `remote_exec_sudo`), YAML parsing
- `.env` — `SSH_PASS` or `SSH_KEY` for remote auth (not in git)

## Deploy Workflow

```
edit config/llama.yaml
       ↓
make deploy-dry     # preview
       ↓
make deploy         # SSH → /etc/llama-server.conf → systemd restart → health check
```

## Make Targets

```
make deploy         Push llama.yaml settings to remote server
make deploy-dry     Preview without applying
make status         Show server status and metrics
make logs           Last 50 log lines
make logs-f         Live log tail
make ssh            SSH into server (with port-forward for metrics)
make test           Remote API tests
make benchmark      k6 load tests
make list-models    List models on remote
make switch-model MODEL=file.gguf
make add-model REPO=org/repo MODEL=file.gguf
```

## Install Scripts

Both install scripts:
- Create `/opt/llm/models/` and download Qwen3-8B, Qwen3-14B, DeepSeek-R1-32B
- Write `/etc/llama-server.conf` and a systemd service unit
- Install `llm-status`, `llm-health`, `llm-logs`, `llm-switch` to `/opt/llm/bin/`
- Optionally set up a Cloudflare Tunnel

Differences: AMD script uses podman + Vulkan image + `dnf` + `firewall-cmd`. NVIDIA script uses docker + CUDA image + `apt` + `ufw` + `nvidia-container-toolkit`.
