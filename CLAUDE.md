# LLM Server — Project Guide

## What This Is

Tooling for deploying and managing llama-server (llama.cpp) inference servers. Install
scripts bootstrap a target machine; `config/llama.yaml` + `make` handle config
deployment, verification, and load testing.

## Architecture — read this before changing deploy

A target runs **one llama-server instance per model**, not a single server:

```
client -> cloudflared -> nginx :8080 (njs router, /etc/llama-router/models.json)
                           |-> 127.0.0.1:8081  llama-server@<name-a>
                           |-> 127.0.0.1:8082  llama-server@<name-b>
```

- `llama-server@.service` is a systemd **template** owned by the target.
- Each instance reads `<instances_dir>/<name>.conf` — those files are what
  `deploy-llama.sh` renders and owns.
- nginx routes on the request's `model` field; the instance name IS the model name.
- Instances bind loopback only.

There is no `/etc/llama-server.conf` on a migrated target. Install scripts still create
one for a fresh single-instance box, but the deploy path does not use it.

## The core invariant

llama.cpp's `-c` is a **total** divided across slots:

```c
n_ctx_seq = kv_unified ? n_ctx : PAD256(n_ctx / n_parallel)
```

So `config/llama.yaml` states `context_per_request` — what one request actually gets —
and deploy derives `-c = context_per_request × parallel_slots`, asserting the result
survives that rounding. Never set `-c` directly; that is how the window silently
became 2816 tokens.

## Key Files

- `config/llama.yaml` — deploy target, `defaults:` + `instances:` (gitignored)
- `config/llama.example.yaml` — the schema of record; a test asserts it stays valid
- `scripts/deploy-llama.sh` — renders instance confs, preflights, restarts only what changed, rolls back on failure
- `scripts/lib/common.sh` — config load/validation (`load_config`, `load_instance`), SSH helpers
- `scripts/verify-deploy.sh` — asserts yaml == deployed conf == live process == `/props`
- `tests/test-render.sh` — offline suite; no network, no SSH
- `.env` — `LLM_HOST`, `LLAMA_API_KEY`, and `SSH_PASS` or `SSH_KEY` (gitignored)

## Workflow

```
edit config/llama.yaml
       ↓
make test-unit      # offline: validation, arithmetic, goldens
       ↓
make deploy-dry     # per-instance diff; names what would restart
       ↓
make deploy         # rollback armed
       ↓
make verify         # config vs deployed vs running process
```

## Make Targets

```
make lint | test-unit | test-context | verify | test | test-models | benchmark
make deploy | deploy-dry | benchmark-accept
make status | logs | logs-f | config | ssh
make start | stop | restart | enable | disable
make list-models | switch-model MODEL=f.gguf [INSTANCE] | add-model REPO=r MODEL=f.gguf
```

## Conventions

- Tests are plain bash with a pass/fail counter, matching `tests/test-*.sh`. A suite
  exits non-zero if any assertion failed.
- Behavioural claims in comments should have a test. `tests/test-render.sh` covers the
  context arithmetic, defaults/override merging, config rejection, and shell quoting.
- Golden files live in `tests/golden/`; regenerate with `make test-unit-accept` and
  **read the diff** — they were once regenerated from a wrong render.
- `yq`'s `//` treats `false` and `""` as absent. Use `has()` for anything boolean or
  string-optional.
- `remote_exec_sudo` consumes stdin to feed `sudo -S`; never pipe file content through
  it. Use `remote_write_sudo`.

## Docs

- `specs/context-window-deploy.md` — architecture, runbook, perf baseline, known issues
- `specs/ollama.md` — why the Ollama backend is installable but unmanaged
