import http from 'k6/http';
import { check, sleep } from 'k6';
import { Trend, Counter, Rate } from 'k6/metrics';

const ENDPOINT = __ENV.LLM_ENDPOINT || (__ENV.LLM_HOST ? `https://${__ENV.LLM_HOST}` : 'http://localhost:8080');
const API_KEY = __ENV.LLAMA_API_KEY || '';
const MODEL = __ENV.LLM_MODEL || '';
const MAX_VUS = parseInt(__ENV.BENCH_MAX_VUS || '8', 10);
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
        { duration: '30s', target: Math.max(1, Math.floor(MAX_VUS / 2)) },
        { duration: '1m', target: MAX_VUS },
        { duration: '30s', target: Math.max(1, Math.floor(MAX_VUS / 2)) },
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
        { duration: '30s', target: Math.max(1, Math.floor(MAX_VUS / 2)) },
        { duration: '1m', target: MAX_VUS },
        { duration: '30s', target: 1 },
      ],
      startTime: '2m40s',
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

  check(res, {
    'status is 200': (r) => r.status === 200,
    'has content': (r) => {
      const c = r.json('choices.0.message.content');
      return c !== undefined && c !== null;
    },
    // finish_reason=length means the turn was cut off. Non-fatal for a
    // throughput test, but it must not go unnoticed.
    'not truncated': (r) => r.json('choices.0.finish_reason') !== 'length',
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
  request('Count to 10 quickly.', 50);
  sleep(1);
}

export function decodeHeavy() {
  request('Count to 10 quickly.', 50);
  sleep(1);
}

export function prefillHeavy() {
  request(LONG_PROMPT, 50);
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
    env: {
      contextPerRequest: __ENV.LLM_CONTEXT_PER_REQUEST || null,
      parallelSlots: __ENV.LLM_PARALLEL_SLOTS || null,
      totalContext: __ENV.LLM_TOTAL_CONTEXT || null,
      model: MODEL || null,
      endpoint: ENDPOINT,
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
