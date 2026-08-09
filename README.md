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

`llama-server@.service` is rendered from `templates/llama-server@.service.in` and
installed by `make deploy` — **that template is the argv**, so every llama-server flag is
in git and reviewable. Each instance also reads `/opt/llm/instances/<name>.conf`, which
deploy renders per model and systemd expands as `${VAR}` inside the unit.

Because all instances share the template, changing it restarts all of them; `make
deploy-dry` says so before you apply. The nginx njs router and its `models.json` remain
target-owned and are not managed here.

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
make deploy-dry   # diffs the unit + each conf; names exactly what would restart
make deploy       # writes what changed, restarts only that, auto-rolls back on failure
make verify       # yaml == conf == live process == /props == /slots, + a real tool call
```

Deploy preflights the target (runtime, GPU, instance files, router map agreement),
preserves each instance's API key rather than rewriting it, reads back what it wrote
before restarting anything, and touches only what actually changed. It also refuses
configs that would break the target rather than discovering it at restart time: an
invalid KV cache type, a missing container image, two instances on one port, an instance
name that would not survive interpolation, or a control character in any value.

## Testing

```bash
make lint          # shellcheck
make test-unit     # offline: config refusal, derived context, defaults/overrides, goldens
make verify        # live: config vs deployed vs process vs /slots, + a streamed tool call
make test-drift    # asserts verify actually goes RED when the target drifts
make test-context  # effective window, long prompts, tool-shaped turns, truncation
make test          # API smoke test
make test-models   # model selection
make benchmark     # k6 load test, compared against bench/baseline.json
make bench-agent   # streamed + tool-calling + multi-turn; gates on correctness
```

`test-unit` needs nothing — no network, no SSH, no server. `verify`, `test-drift` and
`bench-agent` need SSH. The rest need a reachable endpoint.

`make test-context` reads the required window from `config/llama.yaml` for the instance
under test, so it is correct for every instance rather than asserting one fixed number.
Target a specific instance with `LLM_MODEL=<name>`.

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

### Agent-workload benchmark

`make benchmark` cannot see the things that actually break for an agent: it sends no
`tools`, does not stream, and is single-turn. `make bench-agent` replays a recorded
multi-turn tool-using session (`tests/fixtures/agent-session.json`) with streaming on,
and **gates hard on correctness** — tool-argument JSON validity, schema conformance,
`finish_reason`, that the answer arrives in more than one frame, and that warm turns
actually reuse the prompt cache. Those are binary properties, so they cannot flake.
Latency is recorded but advisory, as above.

The replayed history is the *recorded* assistant/tool message rather than the model's live
output, so the prompt prefix is identical every run and percentiles stay comparable.

### Measuring, rather than assuming, what a setting costs

```bash
make kv-study-plan   # disk/time budget and target headroom; changes nothing
make kv-study        # measures KV quantization cost -> specs/kv-quant-study.md
```

Compares `f16` / `q8_0` / `q4_0` KV cache — plus the asymmetric arms that isolate whether
K or V is the sensitive one — over two corpora, one prose and one built from real
tool-calling turns, using `llama-perplexity --kl-divergence`. It reports tail KLD and
top-1 token agreement rather than means, because a malformed tool call is a handful of
tokens going wrong.

## Server management

Every command below covers all instances, or one with `INSTANCE=<name>`:

```bash
make status      # per instance: unit state, restarts, window, slots, metrics, flash-attn
make logs        # recent logs           make logs-f    # live tail
make start | stop | restart | enable | disable
make config      # the target's deployed conf per instance (API key redacted)
make ssh         # SSH in
```

`make status` reads everything from the server rather than inferring it from config,
including the *resolved* flash-attention state — `flash_attn: false` in the config does
not mean it is off. There is no KV-cache-utilisation metric to report; llama.cpp removed
it, so context pressure comes from the per-slot window plus the observed peak.

## Models

```bash
make list-models
make add-model REPO=org/repo MODEL=file.gguf
make switch-model MODEL=file.gguf INSTANCE=name
```

## Docs

- `config/llama.example.yaml` — full config schema
- `templates/llama-server@.service.in` — the actual llama-server argv
- `specs/context-window-deploy.md` — architecture, deploy runbook, perf baseline,
  context-window sizing notes, and known issues
- the consuming app's integration guide lives in that app's repo
  (`apps/twofit-app/src/api/specs/llm-server.md`); the open items on our side are in
  `specs/context-window-deploy.md`
- `specs/kv-quant-study.md` — measured cost of KV quantization (generated by `make kv-study`)
- `specs/ollama.md` — why the Ollama backend is installable but unmanaged
