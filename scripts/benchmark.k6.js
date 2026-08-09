import http from 'k6/http';
import { check, sleep } from 'k6';
import { Trend, Counter, Rate } from 'k6/metrics';

const ENDPOINT = __ENV.LLM_ENDPOINT || (__ENV.LLM_HOST ? `https://${__ENV.LLM_HOST}` : 'http://localhost:8080');
const API_KEY = __ENV.LLAMA_API_KEY || '';
const MODEL = __ENV.LLM_MODEL || '';
// Defaults to parallel_slots (exported by benchmark.sh) so the load actually
// matches the server's concurrency instead of a hardcoded number.
const MAX_VUS = parseInt(__ENV.BENCH_MAX_VUS || '16', 10);
const HALF_VUS = Math.max(1, Math.floor(MAX_VUS / 2));
const MAX_TOKENS = parseInt(__ENV.BENCH_MAX_TOKENS || '100', 10);
const OUT_DIR = __ENV.BENCH_OUT || 'bench';
const LABEL = __ENV.BENCH_LABEL || 'current';

// llama.cpp reports its own timings, which separate prompt processing from
// generation and are immune to network jitter. http_req_duration conflates
// the two, and a context change moves them in opposite directions.
const ttft = new Trend('llm_prompt_ms', true);
const genTps = new Trend('llm_tokens_per_sec');
const outTok = new Counter('llm_output_tokens');
const ctxErr = new Rate('llm_context_errors');

// A ~1200-token prompt: exercises prompt processing, which is what a bigger
// context window actually changes.
const LONG_PROMPT = 'Summarize the following text in one sentence.\n\n'
  + 'the quick brown fox jumps over the lazy dog. '.repeat(110);

export const options = {
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(90)', 'p(95)', 'p(99)', 'count'],
  scenarios: {
    warmup: {
      executor: 'constant-vus',
      vus: 1,
      duration: '10s',
      gracefulStop: '5s',
      tags: { phase: 'warmup' },
    },
    // Short prompt, short output. Should NOT move when context changes.
    decode: {
      executor: 'ramping-vus',
      startVUs: 1,
      stages: [
        { duration: '30s', target: HALF_VUS },
        { duration: '1m', target: MAX_VUS },
        // Sustained plateau: catches thermal throttling and memory growth that
        // a short ramp misses.
        { duration: '3m', target: MAX_VUS },
        { duration: '30s', target: HALF_VUS },
        { duration: '10s', target: 1 },
      ],
      startTime: '20s',
      exec: 'decodeHeavy',
      tags: { phase: 'decode' },
    },
    // Long prompt, short output. This is the shape the change affects.
    prefill: {
      executor: 'ramping-vus',
      startVUs: 1,
      stages: [
        { duration: '30s', target: HALF_VUS },
        { duration: '1m', target: MAX_VUS },
        { duration: '30s', target: 1 },
      ],
      startTime: '5m40s',
      exec: 'prefillHeavy',
      tags: { phase: 'prefill' },
    },
  },
  thresholds: {
    // Tagged by scenario so warmup samples don't pollute the gate.
    'http_req_duration{phase:decode}': ['p(95)<30000'],
    'http_req_duration{phase:prefill}': ['p(95)<45000'],
    'http_req_failed{phase:decode}': ['rate<0.01'],
    'http_req_failed{phase:prefill}': ['rate<0.01'],
    'checks': ['rate>0.99'],
    'llm_context_errors': ['rate<0.001'],
    // A run with too few samples is inconclusive, not green. Without this a
    // scenario that never executed silently passes every threshold above.
    'iterations': ['count>100'],
    // Per-scenario floors, not just a global one. `iterations` above counts all
    // scenarios together, so the prefill phase could contribute ~50 samples and
    // still pass — and a p(95) over 50 points is roughly the 3rd worst
    // observation. These also catch a scenario that failed to execute at all.
    'http_reqs{phase:decode}': ['count>100'],
    'http_reqs{phase:prefill}': ['count>30'],
    // handleSummary only receives a TAGGED submetric if a threshold names that
    // exact selector. http_req_waiting was requested in `wanted` below but never
    // once appeared in a result file, because nothing declared it here. These are
    // deliberately no-op bounds: their job is materialization, not gating.
    'http_req_waiting{phase:decode}': ['p(95)>=0'],
    'http_req_waiting{phase:prefill}': ['p(95)>=0'],
  },
};

function headers() {
  const h = { 'Content-Type': 'application/json' };
  if (API_KEY) h['Authorization'] = `Bearer ${API_KEY}`;
  return h;
}

function request(content, maxTokens) {
  const body = { messages: [{ role: 'user', content }], max_tokens: maxTokens, temperature: 0.7 };
  if (MODEL) body.model = MODEL;

  const res = http.post(`${ENDPOINT}/v1/chat/completions`, JSON.stringify(body), {
    headers: headers(),
    timeout: '120s',
  });

  const overflow = res.status === 400 && String(res.body).includes('exceed_context_size');
  ctxErr.add(overflow);

  // Load-test checks only. finish_reason=length is EXPECTED here because
  // max_tokens is deliberately small and Qwen3 spends tokens on reasoning —
  // whether a turn fits the window is tests/test-context-window.sh's job.
  check(res, {
    'status is 200': (r) => r.status === 200,
    'returned a choice': (r) => {
      const c = r.json('choices.0.message');
      return c !== undefined && c !== null;
    },
    'no context overflow': () => !overflow,
  });

  if (res.status === 200) {
    const t = res.json('timings');
    if (t) {
      if (t.prompt_ms !== undefined) ttft.add(t.prompt_ms);
      if (t.predicted_per_second !== undefined) genTps.add(t.predicted_per_second);
      if (t.predicted_n !== undefined) outTok.add(t.predicted_n);
    }
  }
  return res;
}

export default function () {
  request('Count to 10 quickly.', MAX_TOKENS);
  sleep(1);
}

export function decodeHeavy() {
  request('Count to 10 quickly.', MAX_TOKENS);
  sleep(1);
}

export function prefillHeavy() {
  request(LONG_PROMPT, MAX_TOKENS);
  sleep(1);
}

export function handleSummary(data) {
  const pick = (n) => {
    const m = data.metrics[n];
    return m ? { type: m.type, values: m.values } : null;
  };
  const wanted = [
    'http_req_duration{phase:decode}',
    'http_req_duration{phase:prefill}',
    'http_req_waiting{phase:decode}',
    'http_req_waiting{phase:prefill}',
    'http_req_failed{phase:decode}',
    'http_req_failed{phase:prefill}',
    'http_reqs', 'iterations', 'dropped_iterations', 'checks',
    'llm_prompt_ms', 'llm_tokens_per_sec', 'llm_output_tokens', 'llm_context_errors',
  ];

  const failed = [];
  for (const [name, m] of Object.entries(data.metrics)) {
    for (const [expr, t] of Object.entries(m.thresholds || {})) {
      if (!t.ok) failed.push(`${name}: ${expr}`);
    }
  }

  const record = {
    schema: 1,
    label: LABEL,
    testRunDurationMs: data.state.testRunDurationMs,
    // Stamp the intent, so a baseline is never compared across configs.
    // endpointKind, not the address: a committed baseline shouldn't carry
    // infrastructure detail, and only "same path?" matters for comparison.
    env: {
      contextPerRequest: __ENV.LLM_CONTEXT_PER_REQUEST || null,
      parallelSlots: __ENV.LLM_PARALLEL_SLOTS || null,
      totalContext: __ENV.LLM_TOTAL_CONTEXT || null,
      model: MODEL || null,
      endpointKind: ENDPOINT.startsWith('https://') ? 'public' : 'origin',
      maxVUs: MAX_VUS,
    },
    thresholdsFailed: failed,
    metrics: Object.fromEntries(
      wanted.map((n) => [n, pick(n)]).filter(([, v]) => v !== null)
    ),
  };

  const out = {};
  out[`${OUT_DIR}/${LABEL}.json`] = JSON.stringify(record, null, 2);
  out['stdout'] = '\n' + textSummary(data) + '\n';
  return out;
}

// Minimal inline summary: avoids a network fetch of the jslib at run time,
// which the sandboxed/offline case can't do.
function textSummary(data) {
  const lines = [];
  const fmt = (v) => (typeof v === 'number' ? Math.round(v * 100) / 100 : v);
  for (const name of Object.keys(data.metrics).sort()) {
    const m = data.metrics[name];
    const v = m.values || {};
    const parts = Object.keys(v).map((k) => `${k}=${fmt(v[k])}`);
    lines.push(`  ${name}: ${parts.join(' ')}`);
  }
  return lines.join('\n');
}
