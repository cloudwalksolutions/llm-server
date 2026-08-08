# Ollama backend (untested)

`scripts/install-ollama.sh` exists and is kept for reference, but **nothing in this
repo's test suite covers it**. None of `make deploy`, `make verify`, `make test-context`,
`make test-models`, or `make benchmark` works against an Ollama target — they all assume
llama.cpp semantics (`/props`, per-instance confs, `-c`/`-np` flags, the
`llama-server@<name>.service` template).

Treat anything below as unverified.

## What the install script does

```bash
sudo ./scripts/install-ollama.sh
```

Installs Ollama, configures systemd to bind `0.0.0.0:11434`, opens the firewall, and
optionally calls `scripts/setup-cloudflare.sh` to expose it through a tunnel.

## Why it isn't wired into the tooling

The context-window work this repo is built around does not transfer:

- Ollama sets context per-request (`options.num_ctx`) or per-Modelfile, not via a
  server-wide `-c` divided across slots. The `context_per_request` /
  `parallel_slots` derivation that `config/llama.yaml` encodes has no analogue.
- Concurrency is governed by `OLLAMA_NUM_PARALLEL` / `OLLAMA_MAX_LOADED_MODELS`,
  environment variables on the service, not per-instance config files.
- There is no `/props`, so `make verify`'s core assertion — that the *running* server
  reports the window we asked for — has nothing to read.
- Ollama loads and evicts models on demand with its own keep-alive timer, so the
  one-instance-per-model layout the deploy script manages doesn't apply.

## If you do want to use it

Point a client straight at `http://<host>:11434/v1/` — it speaks the OpenAI-compatible
API. Manage models with `ollama pull` / `ollama list` / `ollama ps` on the box.

To bring it under this repo's tooling properly, someone would need to:

1. Add an `ollama` runtime engine to `runtime.engine` validation in
   `scripts/lib/common.sh`.
2. Decide what `context_per_request` means for it — most likely a per-model Modelfile
   `PARAMETER num_ctx`, written and reloaded by deploy.
3. Give `verify-deploy.sh` something to assert against. `/api/show` returns model
   parameters and is the closest equivalent to `/props`.
4. Add fixtures and golden files so `make test-unit` covers the rendering, exactly as
   the llama.cpp path is covered today.

Until that exists, the honest position is that this backend is installable but unmanaged.

## Known interaction

Ollama and llama.cpp will contend for the same GPU if both run on one box — each keeps
its weights resident. On a machine already serving llama.cpp instances, starting Ollama
can push the total past VRAM and make whichever loads second fail to allocate.
