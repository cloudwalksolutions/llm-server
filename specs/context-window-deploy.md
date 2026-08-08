# Raising the effective context window — deploy runbook

## What this changes and why

TwoFit's tool-using agent turns failed against `llm.cloudwalksolutions.ai` because the
effective per-request context was **2816 tokens**. Measured directly:

```json
{"error":{"message":"request (60009 tokens) exceeds the available context size (2816 tokens)",
 "type":"exceed_context_size_error","n_prompt_tokens":60009,"n_ctx":2816}}
```

**Root cause.** llama.cpp's `-c` is a *total* divided across slots:

```c
n_ctx_seq = kv_unified ? n_ctx : GGML_PAD(n_ctx / n_seq_max, 256)
```

`--kv-unified` is on by default *only when the slot count is auto*. Passing an explicit
`--parallel N` silently turns it off and re-enables the division. Nothing in this repo
knew those two knobs interacted.

**Fix.** `config/llama.yaml` now declares `context_per_request` — what a client actually
gets — and deploy derives `-c = context_per_request × parallel_slots`, emitting
`--no-kv-unified` explicitly rather than relying on a default.

| | before | after |
|---|---|---|
| per request | 2816 | **16384** |
| `-c` | (drifted) | 262144 |
| slots | (drifted) | 16 |

## Prerequisites

1. **SSH access to `192.168.1.168`** (user `walkerobrien`). Add to `.env`:
   ```
   SSH_KEY=~/.ssh/id_ed25519      # or SSH_PASS=...
   ```
   Without this, `make deploy` / `make verify` cannot run.

2. **Tools:** `yq`, `jq`, `k6`. Optional: `shellcheck` for `make lint`.

3. `.env` also needs `LLM_HOST` and `LLAMA_API_KEY` for the endpoint-level tests. Note
   the repo's `LLAMA_API_KEY` is for the dev box; the production key lives in
   `apps/twofit-app/src/api/.env` as `LLAMACPP_API_KEY`.

## Step 0 — Diagnose before changing anything (REQUIRED)

The 2816 has three possible causes and only the live cmdline distinguishes them. **Do
this first** — it also reveals whether prod is in router mode.

```bash
ssh walkerobrien@192.168.1.168 \
  "tr '\0' ' ' < /proc/\$(pgrep -f llama-server | head -1)/cmdline; echo"
ssh walkerobrien@192.168.1.168 \
  "journalctl -u llama-server | grep -E 'n_ctx|n_seq_max|kv_unified|n_slots|rounding' | tail -20"
```

**Stop and reassess if the cmdline has no `-m` flag.** `/v1/models` returns three models
(`qwen3-14b-1m`, `qwen3-14b`, `qwen3-8b`), which suggests router mode (`--models-dir`,
no `-m`). The unit this repo renders passes `-m`, so deploying it would change how prod
serves models. Router mode needs `--models-preset` for per-model context instead.

## Step 1 — Offline checks (no server needed, safe anywhere)

```bash
make lint          # shellcheck, if installed
make test-unit     # 20 tests: golden renders, arithmetic, config validation
make deploy-dry    # shows per-request context + derived flags + a diff vs the target
```

`make test-unit` must be green before going further. It asserts, among others:

- `-c` is `context_per_request × parallel_slots`, not a division
- `--no-kv-unified` is emitted explicitly
- the podman/AMD unit names `llama-server`; the docker/NVIDIA unit must not
- a quantized `cache_type_v` with `flash_attn: false` is **rejected**
- the legacy `context_size` key is rejected with a migration message

## Step 2 — Capture a baseline BEFORE deploying

Regression detection needs a "before". This runs ~7 minutes of load against the endpoint.

```bash
BENCH_LABEL=baseline make benchmark
cp bench/baseline.json bench/baseline.json   # already written by the label
git add -f bench/baseline.json && git commit -m "bench: baseline before context change"
```

The record stamps `contextPerRequest` / `parallelSlots`, so a baseline is never silently
compared across different configs.

## Step 3 — Deploy

```bash
make deploy
```

Sequence: preflight (runtime/GPU/model checks, unit syntax) → back up conf + unit →
write both → `daemon-reload` → restart → health check. On any failure an `ERR` trap
restores both backups, restarts, and re-checks.

The health check asserts more than HTTP 200 — `NRestarts` stable (catches a crash loop
answering from a stale container), unit active, and a real completion returning.

## Step 4 — Verify

```bash
make verify        # llama.yaml == /etc/llama-server.conf == running process
make test-context  # the effective window; must go 3-RED -> green
```

`make verify` compares all three sources, including `-c`/`-np`/`--no-kv-unified` parsed
out of `/proc/<pid>/cmdline` and `/props`'s per-slot `n_ctx`.

`make test-context` is the acceptance gate:

| assertion | before |
|---|---|
| effective `n_ctx` ≥ 16384 | FAIL (2816) |
| a ~6k-token prompt completes | FAIL |
| a tool-shaped turn fits | pass (1928 tokens) |
| no silent truncation (`finish_reason != length`) | FAIL |
| `max_output_tokens` 4096 fits the window | pass |

## Step 5 — Confirm no regression

```bash
make benchmark     # auto-compares against bench/baseline.json
```

Exit codes: `0` clean · `1` regression beyond tolerance · `3` inconclusive (too few
iterations) · `99` k6 SLO breach · `2` bad k6 config (*not* a perf problem).

If a regression is an accepted trade:

```bash
make benchmark-accept && git commit bench/baseline.json -m "bench: accept new baseline"
```

## Step 6 — End-to-end from the client

From `apps/twofit-app/src/api/` with the venv active. Run each **twice** — the old
failure sat on a token boundary, so one green run isn't proof.

```bash
make integration   # test_the_marketing_agent_combines_tool_use...
behave features/marketing_agent.feature
```

## Rollback

Automatic on deploy failure. Manual:

```bash
ssh walkerobrien@192.168.1.168 \
  "ls -t /etc/llama-server.conf.backup.* /etc/systemd/system/llama-server.service.backup.* | head"
# then, as root:
#   cp /etc/llama-server.conf.backup.<ts> /etc/llama-server.conf
#   cp /etc/systemd/system/llama-server.service.backup.<ts> /etc/systemd/system/llama-server.service
#   systemctl daemon-reload && systemctl restart llama-server
make verify
```

## Configuration reference

Full schema and comments: `config/llama.example.yaml`. `config/llama.yaml` is gitignored,
so the example file is the only record of the schema — update it when adding keys.

The three settings most likely to need retuning on this box:

- **`parallel_slots: 16`** × `context_per_request: 16384` → 262144 total.
  KV at f16 ≈ **40 GiB** (40 layers, 160 MiB per 1024 tokens) + ~9 GB model.
- **`flash_attn: false`** — the AMD Vulkan backend has no GPU FA kernel and falls back to
  CPU (~50% loss). A quantized `cache_type_v` would force FA back on, which is why
  `load_config` now rejects that combination instead of letting it pass silently.
- **`ubatch_size: 512`** (not 2048) — with FA off the KQ tensor is materialized and scales
  with `n_ctx × n_ubatch × n_heads`: ~1.3 GB at 512 vs ~5.4 GB at 2048 for 16384-token
  slots. Raise it once the prefill benchmark shows it pays.

## Things deliberately not done

- **No YaRN.** Every framework implements *static* YaRN, so it degrades short prompts.
  Qwen3's native `n_ctx_train` is 40960 — well above our 16384.
- **No KV quantization.** q8_0 is safe (+0.05% perplexity) but forces flash attention on,
  and memory isn't the constraint at 128 GB. If ever enabled, `cache_type_k` and
  `cache_type_v` **must match** — asymmetric pairs fall back to CPU attention silently.
- **`--context-shift` left off.** It converts silent truncation into rambling generation
  with a forgotten middle — worse for a tool-calling agent.
- **`--models-dir` dropped.** It is a no-op alongside `-m` and fatal on images older than
  2025-12.
- **No nginx changes.** `/props` is 404'd at the edge by the reverse proxy, not by
  llama.cpp auth. Exposing a read-only context-window endpoint would let the client team
  self-serve, but it touches production serving and needs separate sign-off.

## Finishing the in-progress merge

A merge of `a0bce03 "rm config"` is currently unresolved in the index. The working tree is
already correct; the remaining steps are git bookkeeping:

```bash
git rm --cached config/llama.yaml          # they untracked it; .gitignore now covers it
git add scripts/lib/common.sh scripts/deploy-llama.sh scripts/benchmark.k6.js
git add config/llama.example.yaml tests/ specs/
git status                                 # confirm nothing unresolved
make test-unit                             # 20/20 before committing
git commit
```
