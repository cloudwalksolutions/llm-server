# Context window — architecture, deploy, and test runbook

## What was wrong

The effective per-request context was **2816 tokens**, so any turn carrying a tool
schema plus a tool result didn't fit.

Root cause, confirmed from the live process:

```
/opt/llm/instances/qwen3-14b.conf:  CONTEXT_SIZE=32768  PARALLEL_SLOTS=12
    -c 32768 -np 12  ->  PAD256(32768/12) = PAD256(2730) = 2816
```

`-c` is a **total** that llama.cpp divides across slots:

```c
n_ctx_seq = kv_unified ? n_ctx : GGML_PAD(n_ctx / n_seq_max, 256)
```

`--kv-unified` defaults on only when the slot count is auto; an explicit `--parallel`
turns it off and re-enables the division. Nothing expressed the number that actually
matters, so 12 slots silently produced 12 unusably small windows.

## Current state

| instance | port | per request | slots | `-c` | KV |
|---|---|---|---|---|---|
| `qwen3-14b-1m` | 8081 | 40960 | 1 | 40960 | q8_0 |
| `qwen3-14b` | 8082 | **16384** | 8 | 131072 | q8_0 |
| `qwen3-8b` | 8083 | 4096 | 8 | 32768 | q8_0 |

`qwen3-14b-1m` moved from `q4_0` to `q8_0` on 2026-08-09 — see
`specs/kv-quant-study.md` for the measurement, and note that the claim which
prompted it (that `q4_0` harms tool calling specifically) was *not* what the
numbers supported.

### Target hardware, as measured

Beelink GTR9 Pro, Fedora, podman, AMD Strix Halo (gfx1151) on Vulkan/RADV.

| | |
|---|---|
| system RAM | 30 GiB |
| VRAM | 98304 MiB (96 GiB), carved out in firmware |
| Vulkan-visible total | 229376 MiB (includes GTT) |
| CPU | 16 physical cores / 32 threads |
| llama.cpp build | `b7966-8872ad212` |
| prefill throughput | ~790 tok/s (Qwen3-14B-Q4_K_M, `-c 8192`) |

The RAM/VRAM split is the part worth remembering: `free -g` shows 30 GiB and
looks alarming, but the GPU's 96 GiB is a separate carve-out — earlier docs
described "128GB total, ~100GB usable" as one undifferentiated pool, which made
memory planning wrong in both directions.

VRAM went from 78904 to ~41400 MiB of 98304. `qwen3-14b-1m` had been set to
`-c 1048576`, but Qwen3's `n_ctx_train` is 40960 and llama.cpp caps a slot there
(`the slot context (1048576) exceeds the training context of the model (40960) - capping`).
It was reserving ~45 GiB of KV for a window it could never use.

The `-1m` in the instance name is a leftover from that misconfiguration and describes
nothing about the model: MEASURED from the startup log, `freq_scale = 1` and
`freq_scale_train = 1`, so **no rope scaling is active** — it is the same
`Qwen3-14B-Q4_K_M.gguf` the coach runs. Going beyond 40960 *would* require YaRN, which
Qwen documents as degrading shorter prompts, but nothing here is paying that cost today.
The observed peak on that instance is 2768 tokens (`make status`, `ctx peak`), so there is
no reason to go looking for more window.

## Architecture

The target does **not** run a single llama-server. It runs one instance per model:

```
Cloudflare -> cloudflared -> nginx :8080 (njs router, /etc/llama-router/models.json)
                               |-> 127.0.0.1:8081  llama-server@qwen3-14b-1m
                               |-> 127.0.0.1:8082  llama-server@qwen3-14b
                               `-> 127.0.0.1:8083  llama-server@qwen3-8b
```

- `llama-server@.service` is a **template** owned by the target, not this repo.
- Each instance reads `/opt/llm/instances/<name>.conf` — these are what `make deploy` owns.
- nginx routes on the request's `model` field via `models.json`.
- Instances bind loopback only; nginx is the sole reachable path.

`config/llama.yaml` mirrors this with a `defaults:` block plus per-instance overrides,
and states `context_per_request` — deploy derives `-c = context_per_request × parallel_slots`
and asserts the result survives PAD256 before touching anything.

## Deploy

```bash
make deploy-dry     # per-instance diff; lists exactly which will restart
make deploy         # writes changed confs, restarts only those, rolls back on failure
make verify         # yaml == deployed conf == live process == /props
```

`make deploy` will refuse to run unless the target has `/opt/llm/instances`, the
`llama-server@.service` template, the configured container runtime, and a router map
whose ports agree with the config. It preserves each instance's API key rather than
rewriting it, reads the written file back before restarting, and restarts only
instances whose rendered config actually changed.

## Tests

| command | scope | needs |
|---|---|---|
| `make test-unit` | 25 offline tests: validation, defaults/override merging, derived context, goldens | nothing |
| `make verify` | 27 live checks across all 3 instances + router map | SSH |
| `make test-context` | effective window, long prompt, tool-shaped turn, silent truncation | endpoint |
| `make benchmark` | k6 decode + prefill load, compared against `bench/baseline.json` | endpoint |

`make test-context` and `make benchmark` accept `LLM_ENDPOINT` to hit the origin
directly, which isolates the server from CDN problems:

```bash
LLM_ENDPOINT=http://<origin-host>:8080 ./tests/test-context-window.sh
LLM_ENDPOINT=http://<origin-host>:8080 make benchmark
```

### Recorded baseline

`bench/baseline.json`, taken at 16384/request × 8 slots against the origin:

| metric | value |
|---|---|
| iterations | 248 |
| HTTP failures | 0 |
| context overflow errors | 0 |
| decode p95 | 13.5 s |
| prefill p95 | 18.9 s |
| prompt processing avg | 106 ms |
| output tokens/sec (aggregate) | 52.9 |

`make benchmark` compares against this and exits 1 on a hard failure, 3 if the run had
too few iterations to be conclusive, 99 on a k6 SLO breach.

**What gates vs. what's advisory.** HTTP failures and context-overflow errors gate hard —
they're stable run to run, so any movement is real. Latency and throughput are reported
but do **not** fail the build: two back-to-back runs against an identical server config
moved decode median +34% while prefill median moved -15%, in opposite directions. The
noise floor on this hardware exceeds any tolerance tight enough to be a useful gate.

To make latency gate meaningfully, run the benchmark 5+ times with no changes, measure
the spread, and set each band to roughly 2x it. The current bands are placeholders sized
from two observations and deliberately wide.

## Known issue: the Cloudflare tunnel

`make test-context` currently fails against the public endpoint with
502s from the edge. This is **not** the inference server:

- origin responds in ~0.65 s and `make verify` passes 27/27
- the same tests pass against `LLM_ENDPOINT=http://<origin-host>:8080`
- nginx's access log shows **no** requests arriving from `127.0.0.1` (the tunnel)
  while the 502s occur
- cloudflared is `active` with 4 registered connections and logs no errors

So Cloudflare is not forwarding to a connected, healthy tunnel. Things to check, in
order: the public hostname route for this tunnel in the Cloudflare dashboard, then
`cloudflared` itself (running 2026.2.0, which warns it is outdated; 2026.7.3 is
current), then the box's network — it is on WiFi (`wlp193s0`), which QUIC tolerates
poorly.

Restarting `cloudflared` restores it briefly (a run at 03:00–03:02 passed 4/5), then it
stops forwarding again. Pinning `protocol: http2` made it worse and was reverted.

## Configuration notes

- **`flash_attn: false` does not disable flash attention.** MEASURED (journal,
  2026-08-08): `flash_attn = auto` → `Flash Attention was auto, set to enabled`. The knob
  only omits `-fa`, leaving llama.cpp on its own `auto` default, which resolves to on —
  and a quantized V cache requires it anyway. `load_instance` warns rather than blocking.
  Read the resolved state from `make status` (`flash-at`); `make test-knobs` asserts the
  absence of `-fa` and reports what llama.cpp decided.
  *An earlier version of this note said llama.cpp "force-enables" it, and elsewhere that
  the AMD Vulkan backend has no FA kernel and falls back to CPU. Neither matches the
  target: FA is enabled, on the GPU. Both claims are withdrawn.*
- **`cache_type_k` and `cache_type_v` must match.** Validation rejects mismatches, so
  this is unreachable through this tooling. The old "25–45× slower on prefill via silent
  CPU fallback" figure was UNSUPPORTED here — upstream attributes that number to a CUDA
  build missing quantized-FA kernels, not to asymmetry as such. What *was* measured on
  this target: an asymmetric arm in `make kv-study` runs several times slower than a
  symmetric one at the same settings, on the GPU. Slower, real, and nothing like 45×.
- **Don't exceed `n_ctx_train`.** llama.cpp caps the slot and the extra KV is wasted,
  which is exactly what the 1M instance was doing. For Qwen3-14B llama.cpp reports
  `n_ctx_train = 40960`; note that is `max_position_embeddings` (32768 trained + 8192 of
  output headroom), so sustained *input* past ~32k is outside what Qwen validated even
  though llama.cpp permits it.
- **KV quantization cost is now measured, not asserted.** See `specs/kv-quant-study.md`
  (`make kv-study`). The previous "q4_0 carries ~50× the perplexity damage of q8_0" had
  no measurement behind it on any hardware; a pilot run here put `q4_0/q4_0` on
  Qwen3-14B at ~91% top-1 token agreement versus f16, which is a real cost but not that
  ratio. Size the KV type from that file.
- **A `false` or `""` override needs `has()`, not yq's `//`.** `//` treats both as
  absent, so a `false` instance value silently reverted to a `true` default. There is a
  regression test for this.

## Open items with the consuming app

The TwoFit agent's asks arrived as `specs/twofit-agent.md`, were answered on
2026-08-09, and the reply now lives in that app's own repo at
`src/api/specs/llm-server.md` — their inbox, their follow-ups. The inbound doc was
deleted per the convention on both sides (a handoff doc goes away once its
follow-ups have landed). What remains here is the part that is *our* decision, plus
the measurements worth not re-deriving.

**Measured facts worth keeping:**

- **The agent instance's real context peak is 2768 tokens**, from
  `llamacpp:n_tokens_max` via `make status`, against a configured 40960. The old
  broken window was 2816 — a 48-token margin, which is a tidy explanation for the
  flakiness that was reported. The counter resets on restart. So the window is not
  the scarce resource the original sizing assumed, and it is the natural thing to
  trade for concurrency.
- **`/no_think` works.** A/B on `qwen3-14b-1m`, identical streamed tool-calling
  request: plain gives 260 chars of `reasoning_content`, `+ /no_think` gives 0, and
  both return `finish_reason: tool_calls` with valid arguments. The app's
  `AGENT_THINKING_ENABLED=false` does what it claims.

**Decisions waiting on them:**

- **`parallel_slots: 1` on `qwen3-14b-1m` means no concurrency at all** — one
  request at a time, and `requests_deferred` was observed reaching 2 while a single
  turn generated. Given the 2768-token peak, `4 slots × 8192 @ q8_0` costs 2720 MiB
  versus 3400 MiB for the current single 40960-token slot at `q8_0`, so more
  concurrency is *cheaper* than the window it replaces. Blocked on how many
  concurrent agent users to size for; that is a product question.
- **Whether to add `-rea off` to the unit template.** `/no_think` suppresses the
  reasoning text but never tells llama.cpp, so server-side state keyed on "is
  thinking enabled" stays enabled. [llama.cpp #20345] claims that disables the GBNF
  grammar compiled from each tool's JSON Schema — which is what makes well-formed
  tool arguments a guarantee rather than good behaviour. **Unverified on this
  build; not asserted.** Adding the flag is a one-line, no-downside change now that
  deploy owns the argv; `make bench-agent` can A/B whether it moves the
  malformed-argument rate before anyone bothers.
- **Renaming `qwen3-14b-1m`.** The name is a leftover from the `-c 1048576` era and
  describes nothing — no rope scaling, same GGUF as the coach. It is also the
  `model` routing key, so a rename needs their `LLAMACPP_MODEL` and our router map
  changed together.

[llama.cpp #20345]: https://github.com/ggml-org/llama.cpp/issues/20345

## Rollback

Automatic on deploy failure. Manual:

```bash
ssh <user>@<host> "ls -t /opt/llm/instances/<name>.conf.backup.* | head"
# as root: cp <backup> /opt/llm/instances/<name>.conf
#          systemctl restart llama-server@<name>
make verify
```
