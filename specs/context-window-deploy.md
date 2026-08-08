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
| `qwen3-14b-1m` | 8081 | 40960 | 1 | 40960 | q4_0 |
| `qwen3-14b` | 8082 | **16384** | 8 | 131072 | q8_0 |
| `qwen3-8b` | 8083 | 4096 | 8 | 32768 | q8_0 |

VRAM went from 78904 to ~41400 MiB of 98304. `qwen3-14b-1m` had been set to
`-c 1048576`, but Qwen3's `n_ctx_train` is 40960 and llama.cpp caps a slot there
(`the slot context (1048576) exceeds the training context of the model (40960) - capping`).
It was reserving ~45 GiB of KV for a window it could never use. Going beyond 40960
requires YaRN rope scaling, which degrades short prompts.

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

- **`flash_attn: false` with a quantized `cache_type_v` does nothing.** llama.cpp
  force-enables flash attention for a quantized V cache. `load_config` warns rather
  than blocking, since this combination is in production and works.
- **`cache_type_k` and `cache_type_v` must match.** Asymmetric pairs fall back to CPU
  attention silently, 25–45× slower on prefill. Validation rejects mismatches.
- **Don't exceed `n_ctx_train` (40960 for Qwen3).** llama.cpp caps the slot and the
  extra KV is wasted, which is exactly what the 1M instance was doing.
- **q4_0 KV carries ~50× the perplexity damage of q8_0.** `qwen3-14b-1m` still uses it;
  worth revisiting now that it only needs 40960 tokens of cache.
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
