# Effective context is 2816 tokens — too small for tool-using agents

**Reported:** 2026-08-07, from the TwoFit app repo (`apps/twofit-app`)
**Endpoint:** `https://llm.cloudwalksolutions.ai` · model `qwen3-14b`
**Ask:** raise the *effective per-request* context to **≥ 8192 tokens**
**Status:** TwoFit has mitigated its side by disabling extended reasoning — see
[Mitigation](#mitigation-on-the-client-side) below. Its tests are green again, so
this is no longer breaking us. The context ask still stands: it's what would let
us turn reasoning back on and give tool-using turns real headroom.

## What's going on

TwoFit's agents reach this server via `AGENT_PROVIDER=llamacpp`. Any turn that
involves a tool call fails, because the whole turn doesn't fit in the context
window the server actually gives a request.

Measured from the client side: the effective context is **2816 tokens**. The
TwoFit marketing agent's first turn — instruction + tool schema + the model's
reasoning + one web-search tool call + the tool's response + the final reply —
comes to roughly **2817**. It misses by about one token, which is why the
failure is borderline flaky rather than consistent: the same request passes or
fails run to run depending on how long the model happens to reason.

Two observed failure signatures, both from the same cause:

- `ContextWindowExceededError ... n_ctx: 2816`
- `finish_reason=MAX_TOKENS` with the model's entire output budget spent on
  reasoning tokens and **empty** final content (HTTP 200, empty reply — so it
  reads like an app bug, not a server limit)

## Worth checking: config says 32768, requests see 2816

`config/llama.yaml` in this repo currently has:

```yaml
llama:
  parallel_slots: 8
  context_size: 32768
```

But requests are getting 2816. Two things to rule out — flagging rather than
diagnosing, since we only have client-side visibility:

1. **Context is divided across parallel slots.** llama-server splits
   `--ctx-size` across `--parallel` slots, so total ÷ slots is what any single
   request actually gets. Whatever the deployed numbers are, it's the
   **per-slot** result that matters to us, not the total.
2. **Deployed config may have drifted from this file.** `config/llama.yaml`
   isn't in git, so the running `/etc/llama-server.conf` may not match it.
   2816 doesn't divide evenly out of 32768, which suggests the live values
   differ from what's in this file.

We couldn't confirm either from our side: `GET /props` returns `403 Forbidden`
with our API key.

## Impact

Every TwoFit lifecycle (local, dev, stage, prod) points at this one endpoint,
so this fails everywhere, not just locally:

- `features/marketing_agent.feature:12` — "The marketing agent's reply is
  structured JSON matching the schema" (Behave E2E)
- `agent/tests/test_integration.py::test_the_marketing_agent_combines_tool_use_and_a_parseable_reply`

Non-tool agent turns and the match recommender are unaffected — they fit in
2816 today, though they have no headroom.

## What we need

Effective per-request context of **≥ 8192 tokens** (16384 would leave real
headroom as agents grow). If that means trading down `parallel_slots` for a
bigger per-slot window, that trade is worth it for our workload — our agent
traffic is low-concurrency and latency-tolerant, but it is hard-blocked by a
small window.

TwoFit also currently requests `max_output_tokens=4096`
(`agent/base/providers.py`), which is larger than the entire 2816 window. We'll
keep that value once the window is bigger; noting it so the numbers aren't
surprising in the logs.

## Mitigation on the client side

TwoFit now disables qwen3's extended reasoning pass (appends `/no_think`),
gated by an `AGENT_THINKING_ENABLED` setting that defaults to off. Reasoning was
consuming most of the window, so removing it makes a tool-using turn fit in 2816
with room to spare. Measured effect:

| | before | after |
|---|---|---|
| marketing agent E2E | flaky failure, ~25s | passes, ~12s (3 consecutive runs) |
| `make integration` | 1 failed, 95s | all pass, 36s |
| full E2E suite | 1 failed, 3m22s | all pass, 2m33s |

So the small window is no longer blocking us, and reasoning is one env var away
from coming back whenever the server can afford it.

## How to verify the fix

From the TwoFit repo (`src/api/`), with the venv active:

```bash
make integration    # expect test_the_marketing_agent_combines_tool_use... to pass
behave features/marketing_agent.feature
```

These pass today thanks to the mitigation above, so they no longer prove
anything about the window on their own. To actually verify a bigger context, flip
reasoning back on for the run — that's the configuration the small window broke:

```bash
AGENT_THINKING_ENABLED=true make integration
AGENT_THINKING_ENABLED=true behave features/marketing_agent.feature
```

Run each a couple of times. Because the failure sits right on the boundary, a
single green run isn't proof — that mistake was made once already while
diagnosing this.

Handy for confirming the window directly, if `/props` is opened up to our key:

```bash
curl -s -H "Authorization: Bearer $LLAMACPP_API_KEY" \
  https://llm.cloudwalksolutions.ai/props \
  | jq '.default_generation_settings.n_ctx'
```

---

## RESOLVED — 2026-08-08

Confirmed root cause from the live process: the instance was running
`-c 32768 -np 12`, and llama.cpp divides `-c` across slots
(`PAD256(32768/12) = 2816`). Both reported signatures came from that one setting.

Effective per-request context is now **16384** (`-c 131072 -np 8`), verified from the
server's own `/props`. `config/llama.yaml` now states `context_per_request` directly and
deploy derives `-c`, so this class of bug can't recur silently.

Note the endpoint runs one llama-server per model behind an nginx router, so
`/props` is not reachable from outside — `make verify` reads it on the target.

See `specs/context-window-deploy.md`.
