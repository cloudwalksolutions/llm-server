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

## Memory, as measured

AMD Strix Halo (gfx1151), Vulkan/RADV, 124 GiB of unified memory. The firmware
carve-out is at its minimum and the GPU allocates GTT from system RAM, capped at
112 GiB so the host keeps 12 (`make verify` asserts both). GTT and RAM are one pool:
memory the GPU holds is memory the host does not have.

With the 35B (f16 KV, a 393216-token shared pool, its vision projector) and
gpt-oss-120b loaded: **GTT 109.1 of 112 GiB used, 10 GiB of host RAM available**
(2026-11-18, llamacpp-b12479). Anything that loads a second copy of a model,
such as `kv-quant-study.sh`, needs instances stopped first; its `--plan` says.

## Why the 35B runs this shape

Measured on llamacpp-b12479 with every instance stopped (`kv-quant-study.sh`):

- **Prefill falls with depth** — q8_0 KV, tok/s for 2048 new tokens at depth
  0 / 32k / 131k / 250k: 2071 / 1263 / 595 / 367. f16 is the same speed at every
  depth; q4_0 is half as fast past 32k. Concurrent traffic on another instance can
  halve these, so measure only on a quiet GPU.
- **q8_0 KV costs tool-calling content at depth.** At 64k, versus f16, q8_0's
  99.9% KLD on tool turns is 14.8 (prose 0.11), with 2.3pp more top-1 flips
  (`specs/kv-quant-study.md`). f16 costs memory only, so the 35B runs f16.
- **f16 at 262k is 5 GiB per slot**; three dedicated slots would not fit. One
  `--kv-unified` pool of 393216 tokens (7.5 GiB) lets any request reach the
  model's native 262144 while three run at once; overlapping very long chats
  compete for the pool.
- **A full pool evicts a cached prefix**, and the next turn reprocesses it from scratch:
  a ~128k session lost its cache twice and its p95 time to first token went from 48s
  to 200s, while the GPU was busy for minutes. `cache_ram: 4096` parks evicted states
  in host RAM instead (states over 4096 MiB are still skipped); host RAM available
  went from 10 to 7 GiB.
- **The KLD reference at 131k is OOM-killed** (>85 GB of logits in host RAM), so
  64k is this host's ceiling for the quality study.

## Architecture

The target does **not** run a single llama-server. It runs one instance per model:

```
Cloudflare -> cloudflared -> nginx :8080 (njs router, /etc/llama-router/models.json)
                               |-> 127.0.0.1:<port>  llama-server@<model-a>
                               `-> 127.0.0.1:<port>  llama-server@<model-b>
```

- `llama-server@.service` is rendered from `templates/llama-server@.service.in` and installed by deploy.
- Each instance reads `/opt/llm/instances/<name>.conf`, also rendered by deploy.
- nginx routes on the request's `model` field via `models.json`.
- Instances bind loopback only; nginx is the sole reachable path.

`config/llama.yaml` states `context_per_request`. Deploy derives
`-c = context_per_request × parallel_slots` and asserts it survives PAD256, or, with
`kv_unified: true`, passes `--kv-unified` and `-c = kv_pool`, a pool every slot shares.

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

## Rollback

Automatic on deploy failure. Manual:

```bash
ssh <user>@<host> "ls -t /opt/llm/instances/<name>.conf.backup.* | head"
# as root: cp <backup> /opt/llm/instances/<name>.conf
#          systemctl restart llama-server@<name>
make verify
```
