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

- `llama-server@.service` is a systemd **template**, vendored at
  `templates/llama-server@.service.in` and rendered + installed by `deploy-llama.sh`.
  **That file is the argv** — every llama-server flag lives there, not on the target.
- Each instance reads `<instances_dir>/<name>.conf` — also rendered by deploy. systemd
  expands those as `${VAR}` inside the unit.
- nginx routes on the request's `model` field; the instance name IS the model name.
  The nginx njs router and its `models.json` are still target-owned and unmanaged.
- Instances bind loopback only.

There is no `/etc/llama-server.conf` on a migrated target. Install scripts still create
one for a fresh single-instance box, but the deploy path does not use it.

**Two substitution layers in the unit template, do not mix them:** at-sign placeholders
are resolved by deploy from `llama.yaml` (deploy refuses to install if any survive);
`${VAR}` and `%i` are left for systemd. A change to the template restarts **every**
instance, since they share it — `make deploy-dry` says so.

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
- `templates/llama-server@.service.in` — the unit template, i.e. the actual argv
- `scripts/deploy-llama.sh` — renders the unit + instance confs, preflights, restarts only what changed, rolls back on failure
- `scripts/lib/common.sh` — config load/validation (`load_config`, `load_instance`), SSH helpers
- `scripts/verify-deploy.sh` — asserts yaml == conf == live process == `/props` == `/slots`, **and makes a real streamed tool call**
- `scripts/kv-quant-study.sh` — measures what KV quantization costs; writes `specs/kv-quant-study.md`
- `scripts/bench-agent.sh` — streamed, tool-calling, multi-turn benchmark; gates on correctness
- `tests/test-render.sh` — offline suite; no network, no SSH
- `tests/test-verify-detects-drift.sh` — asserts `make verify` actually goes red on drift
- `tests/fixtures/agent-session.json` — the recorded session `bench-agent` replays
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
make lint | test-unit | test-context | verify | test-drift | test | test-models
make deploy | deploy-dry | benchmark | benchmark-accept | bench-agent
make kv-study-plan | kv-study
make status | logs | logs-f | config | ssh          # all accept INSTANCE=<name>
make start | stop | restart | enable | disable      # all accept INSTANCE=<name>
make list-models | switch-model MODEL=f.gguf INSTANCE=name | add-model REPO=r MODEL=f.gguf
```

## Conventions

- Tests are plain bash with a pass/fail counter, matching `tests/test-*.sh`. A suite
  exits non-zero if any assertion failed, and refuses an unknown test name rather than
  passing with zero tests run.
- **Assert behaviour, not implementation.** Prefer what the server reports or does
  (`/props`, `/slots`, `timings`, a real streamed tool call) over argv greps, journal
  greps or file text; and prefer outcomes of the deploy path ("this config is refused",
  "verify catches this drift") over the internals of helper functions. A flag can be
  right while the capability is broken, and the flags have already moved once.
- Behavioural claims in comments should have a test. `tests/test-render.sh` covers the
  context arithmetic, defaults/override merging, config refusal, and shell quoting.
- **Do not assert `/props → chat_template_caps.supports_tools`.** It reads `false` on
  the deployed build while tool calls work. It describes the template, not the server.
- Golden files live in `tests/golden/`; regenerate with `make test-unit-accept` and
  **read the diff** — they were once regenerated from a wrong render.
- `yq`'s `//` treats `false` and `""` as absent. Use `has()` for anything boolean or
  string-optional.
- `remote_exec_sudo` consumes stdin to feed `sudo -S`; never pipe file content through
  it. Use `remote_write_sudo`.

## Docs

- `specs/context-window-deploy.md` — architecture, runbook, perf baseline, known issues
- `specs/context-window-deploy.md` also carries **Open items with the consuming app** —
  the measured facts and the decisions still waiting on them. The reply to their asks
  lives in their repo (`apps/twofit-app/src/api/specs/llm-server.md`), not here.
- `specs/kv-quant-study.md` — measured cost of KV quantization (generated; do not hand-edit)
- `specs/ollama.md` — why the Ollama backend is installable but unmanaged

## A standing caution

This repo has a history of stating theory in the same voice as measurement. Numbers like
"q4_0 is ~50x the perplexity damage of q8_0" and "asymmetric K/V is 25-45x slower" were
asserted for a long time with nothing behind them — the first is really ~20x, the second
is not a CPU fallback at all (`specs/kv-quant-study.md`).

The 2816-token outage came from exactly this. A tuning doc carried a confident KV memory
table that was ~4x wrong AND treated `context_size` as per-slot rather than a total, and
its "memory headroom allows increasing to 16+ slots safely" was acted on. That doc has been
deleted; the arithmetic that replaces it is under "The core invariant" above and is now
enforced by `deploy --check` and asserted live by `/slots`.

If you add a number, say where it came from; if you cannot, mark it UNMEASURED.

Known live gotcha: `flash_attn: false` does **not** disable flash attention. It omits `-fa`,
leaving llama.cpp on `auto`, which resolves to enabled on this target. Read the resolved
value from `make status` (`flash-at`).
