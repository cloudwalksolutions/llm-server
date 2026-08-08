# LLM Server

Setup and remote management for local LLM inference servers, with optional Cloudflare
Tunnel exposure.

## Install

| Backend | Script | OS | Use case |
|---------|--------|----|----------|
| **llama.cpp (AMD)** | `scripts/install-llama.sh` | Fedora | AMD GPU (Strix Halo), Vulkan |
| **llama.cpp (NVIDIA)** | `scripts/install-llama-nvidia.sh` | Ubuntu/Mint | NVIDIA GPU, CUDA |

```bash
sudo ./scripts/install-llama.sh          # or install-llama-nvidia.sh
```

Each downloads models, writes a systemd service, installs `llm-status` / `llm-health` /
`llm-logs` / `llm-switch`, and optionally sets up a Cloudflare Tunnel via
`scripts/setup-cloudflare.sh`.

An Ollama installer also exists (`scripts/install-ollama.sh`), but none of the management
or test targets below work against it — see `specs/ollama.md`.

## Architecture

A target may run **one llama-server instance per model**, each on its own loopback port,
with nginx routing on the request's `model` field:

```
client -> cloudflared -> nginx :8080 (njs router, /etc/llama-router/models.json)
                           |-> 127.0.0.1:8081  llama-server@<model-a>
                           |-> 127.0.0.1:8082  llama-server@<model-b>
                           `-> 127.0.0.1:8083  llama-server@<model-c>
```

`llama-server@.service` is a template owned by the target. Each instance reads
`/opt/llm/instances/<name>.conf` — those files are what `make deploy` owns and rewrites.

## Setup

Create `.env` (gitignored):

```bash
LLM_HOST='llm.example.com'        # public endpoint, used by the test targets
LLAMA_API_KEY='<64-char key>'     # must match the key on the target
SSH_PASS='...'                    # or SSH_KEY='~/.ssh/id_ed25519'
```

Then `make setup` to create `config/llama.yaml` from the example, and point
`remote.host` / `remote.user` at your target.

## Configuration

`config/llama.yaml` has a `defaults:` block and a per-instance `instances:` block.
Full schema and commentary: `config/llama.example.yaml`.

```yaml
defaults:
  cache_type_k: q8_0
  cache_type_v: q8_0        # must equal cache_type_k
  flash_attn: false

instances:
  my-model:
    port: 8082
    model_file: Qwen3-14B-Q4_K_M.gguf
    context_per_request: 16384      # what ONE request gets
    parallel_slots: 8
```

**`context_per_request` is the number that matters.** llama.cpp's `-c` is a *total* it
divides across slots (`n_ctx_seq = PAD256(n_ctx / n_parallel)` unless `--kv-unified`),
so setting `-c` directly is how you end up serving 2816-token windows by accident.
Deploy derives `-c = context_per_request × parallel_slots` and refuses to proceed if the
result wouldn't survive llama.cpp's rounding.

## Deploy

```bash
make deploy-dry   # per-instance diff; names exactly which instances would restart
make deploy       # writes changed confs, restarts only those, auto-rolls back on failure
make verify       # asserts yaml == deployed conf == live process == /props
```

Deploy preflights the target (runtime, GPU, instance files, router map agreement),
preserves each instance's API key rather than rewriting it, reads back what it wrote
before restarting anything, and touches only instances whose config actually changed.

## Testing

```bash
make lint          # shellcheck
make test-unit     # offline: validation, defaults/overrides, derived context, goldens
make verify        # live: config vs deployed vs running process, all instances
make test-context  # effective window, long prompts, tool-shaped turns, truncation
make test          # API smoke test
make test-models   # model selection
make benchmark     # k6 load test, compared against bench/baseline.json
```

`test-unit` needs nothing — no network, no SSH, no server. `verify` needs SSH. The rest
need a reachable endpoint.

To test the origin directly and rule out CDN problems:

```bash
LLM_ENDPOINT=http://<host>:8080 make test-context
LLM_ENDPOINT=http://<host>:8080 make benchmark
```

### Load testing

`make benchmark` runs two shapes — decode-heavy (short prompt, control) and
prefill-heavy (long prompt, sensitive to context changes) — records llama.cpp's own
`timings`, and diffs against the committed `bench/baseline.json`. Exit codes: `1`
hard failure, `3` inconclusive (too few iterations), `99` k6 SLO breach, `2` bad k6 config.

Errors gate hard; latency and throughput are advisory, because run-to-run variance on
this hardware is wider than any useful tolerance. See `specs/context-window-deploy.md`
for how to turn them into real gates.

Accept a new baseline when a trade is deliberate:

```bash
make benchmark-accept && git commit bench/baseline.json
```

## Server management

```bash
make status      # status + metrics (slot context, queued requests, KV usage)
make logs        # recent logs           make logs-f    # live tail
make start | stop | restart | enable | disable
make config      # show the target's deployed config
make ssh         # SSH in, metrics port-forwarded
```

## Models

```bash
make list-models
make add-model REPO=org/repo MODEL=file.gguf
make switch-model MODEL=file.gguf
```

## Docs

- `config/llama.example.yaml` — full config schema
- `specs/context-window-deploy.md` — architecture, deploy runbook, perf baseline,
  context-window sizing notes, and known issues
- `specs/ollama.md` — why the Ollama backend is installable but unmanaged
