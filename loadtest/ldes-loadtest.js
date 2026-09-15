import http from 'k6/http';
import { check } from 'k6';
import { Counter, Trend } from 'k6/metrics';
import { randomSeed } from 'k6';

/**
 * Load test for an LDES test environment.
 *
 * Two scenarios run side by side, which is what the environment is meant to exercise:
 *
 *  - `ingest`  posts version objects to the LDES server at a constant arrival rate;
 *  - `replicate` reads the paged view the way a consumer (and LDIO) does.
 *
 * Every knob is an environment variable so the workflow can drive it from repository variables
 * without editing this file. The member shape must stay in sync with the SPARQL sink query in
 * terraform/modules/ldes-stack/ldio.tf, hence MEMBER_VOCABULARY.
 */

const INGEST_URL = requireEnv('INGEST_URL');
const VIEW_URL = requireEnv('VIEW_URL');
const MEMBER_VOCABULARY = __ENV.MEMBER_VOCABULARY || 'https://openldes.org/ns/loadtest#';

const INGEST_RATE = parseInt(__ENV.INGEST_RATE || '50', 10);
const INGEST_DURATION = __ENV.INGEST_DURATION || '3m';
const INGEST_VUS = parseInt(__ENV.INGEST_VUS || '20', 10);
const READ_VUS = parseInt(__ENV.READ_VUS || '5', 10);
const READ_RATE = parseInt(__ENV.READ_RATE || '10', 10);
const SUBJECT_COUNT = parseInt(__ENV.SUBJECT_COUNT || '1000', 10);
const BATCH_SIZE = parseInt(__ENV.BATCH_SIZE || '1', 10);

const MAX_FAILED_RATE = __ENV.MAX_FAILED_RATE || '0.01';
const INGEST_P95_MS = __ENV.INGEST_P95_MS || '2000';
const READ_P95_MS = __ENV.READ_P95_MS || '3000';

const membersIngested = new Counter('ldes_members_ingested');
const ingestDuration = new Trend('ldes_ingest_duration', true);
const fetchDuration = new Trend('ldes_fetch_duration', true);

randomSeed(__ENV.RANDOM_SEED ? parseInt(__ENV.RANDOM_SEED, 10) : 20260101);

export const options = {
  discardResponseBodies: false,
  scenarios: {
    ingest: {
      executor: 'constant-arrival-rate',
      rate: INGEST_RATE,
      timeUnit: '1s',
      duration: INGEST_DURATION,
      preAllocatedVUs: INGEST_VUS,
      maxVUs: INGEST_VUS * 4,
      exec: 'ingest',
    },
    replicate: {
      executor: 'constant-arrival-rate',
      rate: READ_RATE,
      timeUnit: '1s',
      duration: INGEST_DURATION,
      preAllocatedVUs: READ_VUS,
      maxVUs: READ_VUS * 4,
      exec: 'replicate',
    },
  },
  thresholds: {
    'http_req_failed{scenario:ingest}': [`rate<${MAX_FAILED_RATE}`],
    'http_req_failed{scenario:replicate}': [`rate<${MAX_FAILED_RATE}`],
    'ldes_ingest_duration': [`p(95)<${INGEST_P95_MS}`],
    'ldes_fetch_duration': [`p(95)<${READ_P95_MS}`],
  },
};

function requireEnv(name) {
  const value = __ENV[name];
  if (!value) {
    throw new Error(`Missing required environment variable ${name}`);
  }
  return value.replace(/\/+$/, '');
}

function member(subject, timestamp) {
  const base = 'https://openldes.org/ns/loadtest/device';
  const versionIri = `${base}/${subject}/${timestamp}`;

  return `@prefix dcterms: <http://purl.org/dc/terms/> .
@prefix xsd: <http://www.w3.org/2001/XMLSchema#> .
@prefix lt: <${MEMBER_VOCABULARY}> .

<${versionIri}>
    a lt:Observation ;
    dcterms:isVersionOf <${base}/${subject}> ;
    dcterms:created "${timestamp}"^^xsd:dateTime ;
    lt:value "${(Math.random() * 100).toFixed(3)}" .
`;
}

function batch(size) {
  const timestamp = new Date().toISOString();
  let body = '';

  for (let i = 0; i < size; i++) {
    const subject = Math.floor(Math.random() * SUBJECT_COUNT);
    // A unique suffix keeps version IRIs distinct when several members share a millisecond.
    const unique = `${timestamp.slice(0, -1)}${String(i).padStart(3, '0')}Z`;
    body += member(subject, unique);
  }

  return body;
}

export function ingest() {
  const response = http.post(INGEST_URL, batch(BATCH_SIZE), {
    headers: { 'Content-Type': 'text/turtle' },
    tags: { name: 'ingest' },
  });

  ingestDuration.add(response.timings.duration);

  const ok = check(response, {
    'ingest accepted': (r) => r.status >= 200 && r.status < 300,
  });

  if (ok) {
    membersIngested.add(BATCH_SIZE);
  }
}

export function replicate() {
  const response = http.get(VIEW_URL, {
    headers: { Accept: 'text/turtle' },
    tags: { name: 'view' },
  });

  fetchDuration.add(response.timings.duration);

  check(response, {
    'view served': (r) => r.status === 200,
    'view is an LDES fragment': (r) => typeof r.body === 'string' && r.body.includes('tree:'),
  });
}

export function handleSummary(data) {
  return {
    'loadtest-summary.json': JSON.stringify(data, null, 2),
    'loadtest-summary.md': markdownSummary(data),
    stdout: textSummary(data),
  };
}

function metric(data, name, field) {
  const values = data.metrics[name] && data.metrics[name].values;
  if (!values || values[field] === undefined) {
    return null;
  }
  return values[field];
}

function format(value, unit) {
  if (value === null) {
    return 'n/a';
  }
  return `${value.toFixed(unit === '' ? 0 : 2)}${unit}`;
}

function markdownSummary(data) {
  const failures = metric(data, 'http_req_failed', 'rate');
  const rows = [
    ['Members ingested', format(metric(data, 'ldes_members_ingested', 'count'), '')],
    ['Ingest requests/s', format(metric(data, 'http_reqs', 'rate'), '/s')],
    ['Ingest p95', format(metric(data, 'ldes_ingest_duration', 'p(95)'), ' ms')],
    ['Ingest max', format(metric(data, 'ldes_ingest_duration', 'max'), ' ms')],
    ['View p95', format(metric(data, 'ldes_fetch_duration', 'p(95)'), ' ms')],
    ['Failed requests', failures === null ? 'n/a' : `${(failures * 100).toFixed(2)} %`],
  ];

  const thresholds = Object.entries(data.metrics)
    .filter(([, m]) => m.thresholds)
    .flatMap(([name, m]) =>
      Object.entries(m.thresholds).map(([expression, result]) => ({
        name,
        expression,
        ok: result.ok === true,
      })),
    );

  const passed = thresholds.every((t) => t.ok);

  return [
    `### Load test ${passed ? 'passed' : 'failed'}`,
    '',
    '| Metric | Value |',
    '| --- | --- |',
    ...rows.map(([key, value]) => `| ${key} | ${value} |`),
    '',
    '| Threshold | Result |',
    '| --- | --- |',
    ...thresholds.map((t) => `| \`${t.name}: ${t.expression}\` | ${t.ok ? 'pass' : 'fail'} |`),
    '',
  ].join('\n');
}

function textSummary(data) {
  const lines = ['', 'LDES load test summary', '----------------------'];

  for (const [name, m] of Object.entries(data.metrics)) {
    if (!m.values) {
      continue;
    }
    const values = Object.entries(m.values)
      .map(([key, value]) => `${key}=${typeof value === 'number' ? value.toFixed(2) : value}`)
      .join(' ');
    lines.push(`${name}: ${values}`);
  }

  return lines.join('\n') + '\n';
}
