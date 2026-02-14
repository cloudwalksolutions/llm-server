import http from 'k6/http';
import { check, sleep } from 'k6';

const ENDPOINT = __ENV.LLM_HOST ? `https://${__ENV.LLM_HOST}` : 'http://localhost:8080';
const API_KEY = __ENV.LLAMA_API_KEY || '';

export const options = {
  scenarios: {
    warmup: {
      executor: 'constant-vus',
      vus: 1,
      duration: '10s',
      tags: { test: 'warmup' },
    },
    load_test: {
      executor: 'ramping-vus',
      startVUs: 1,
      stages: [
        { duration: '30s', target: 4 },
        { duration: '1m', target: 8 },
        { duration: '30s', target: 4 },
        { duration: '10s', target: 1 },
      ],
      startTime: '10s',
      tags: { test: 'load' },
    },
  },
  thresholds: {
    http_req_duration: ['p(95)<30000'],
    http_req_failed: ['rate<0.1'],
  },
};

export default function () {
  const headers = {
    'Content-Type': 'application/json',
  };

  if (API_KEY) {
    headers['Authorization'] = `Bearer ${API_KEY}`;
  }

  const payload = JSON.stringify({
    messages: [
      { role: 'user', content: 'Count to 10 quickly.' }
    ],
    max_tokens: 50,
    temperature: 0.7,
  });

  const res = http.post(`${ENDPOINT}/v1/chat/completions`, payload, {
    headers: headers,
    timeout: '120s',
  });

  check(res, {
    'status is 200': (r) => r.status === 200,
    'has response': (r) => r.json('choices.0.message.content') !== undefined,
  });

  sleep(1);
}
