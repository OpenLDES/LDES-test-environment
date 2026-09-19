import http from 'k6/http';
import exec from 'k6/execution';
import { check } from 'k6';
import { Counter, Trend } from 'k6/metrics';

import {
  catalog,
  buildRuntime,
  ingestUrl,
  queryTargets,
  seedCount,
  loadtestCount,
  loadtestRate,
  ingestSeconds,
  ingestPhaseSeconds,
  metricName,
  INGEST_VUS,
  QUERY_VUS,
  QUERY_RATE,
  QUERY_DURATION_SECONDS,
  SETTLE_SECONDS,
  SEQUENCE_OFFSET,
  REQUEST_TIMEOUT,
} from './lib/config.js';

/**
 * Load test for the multi stream LDES test environment.
 *
 * The run has two phases:
 *
 *  1. *ingest* - one scenario per event stream, each publishing its own number of members at its
 *     own rate. Ingestion is done by a single virtual user per stream (INGEST_VUS), because that
 *     is what a publishing system usually looks like: one writer per data source.
 *  2. *query*  - a configurable number of virtual users (QUERY_VUS) reads every view of every
 *     stream round robin, following a TREE relation into a fragment whenever the view offers one.
 *
 * Between the two there is a settle period, because the LDES server fragments asynchronously.
 *
 * Everything is parameterised through environment variables; see loadtest/lib/config.js and the
 * README. The run writes three artefacts:
 *
 *   loadtest-summary.json   the raw k6 summary
 *   loadtest-metrics.json   a structured per stream / per view summary, consumed by the
 *                           PostgreSQL validation and the report
 *   loadtest-summary.md     a Markdown table for the pull request comment
 */

const INGEST_P95_MS = __ENV.INGEST_P95_MS || '2000';
const QUERY_P95_MS = __ENV.QUERY_P95_MS || '3000';
const MAX_FAILED_RATE = __ENV.MAX_FAILED_RATE || '0.01';

const TARGETS = queryTargets();

const totalIngested = new Counter('ldes_members_ingested');
const totalQueries = new Counter('ldes_queries');
const fragmentsFollowed = new Counter('ldes_fragments_followed');
const ingestDuration = new Trend('ldes_ingest_ms', true);
const queryDuration = new Trend('ldes_query_ms', true);

const ingested = {};
const duplicated = {};
const ingestFailed = {};
const ingestTrend = {};

for (const stream of catalog.streams) {
  const key = metricName(stream.name, 'total');
  ingested[stream.name] = new Counter(`ingested_${key}`);
  duplicated[stream.name] = new Counter(`duplicate_${key}`);
  ingestFailed[stream.name] = new Counter(`ingest_failed_${key}`);
  ingestTrend[stream.name] = new Trend(`ingest_ms_${key}`, true);
}

const queryTrend = {};
const queryCount = {};
const queryFailed = {};

for (const target of TARGETS) {
  queryTrend[target.key] = new Trend(`query_ms_${target.metric}`, true);
  queryCount[target.key] = new Counter(`query_count_${target.metric}`);
  queryFailed[target.key] = new Counter(`query_failed_${target.metric}`);
}

const INGEST_PHASE_SECONDS = ingestPhaseSeconds();
const QUERY_START_SECONDS = INGEST_PHASE_SECONDS + SETTLE_SECONDS;

export const options = {
  discardResponseBodies: false,
  scenarios: buildScenarios(),
  thresholds: buildThresholds(),
};

function buildScenarios() {
  const scenarios = {};

  for (const stream of catalog.streams) {
    const members = loadtestCount(stream);
    if (members === 0) {
      continue;
    }

    scenarios[scenarioName(stream.name)] = {
      executor: 'constant-arrival-rate',
      rate: loadtestRate(stream),
      timeUnit: '1s',
      duration: `${ingestSeconds(stream)}s`,
      // Deliberately not over-allocated: the number of publishing users is a property of the
      // scenario being simulated, not a knob to reach a rate at any cost. A rate the configured
      // users cannot sustain shows up as dropped iterations in the summary.
      preAllocatedVUs: INGEST_VUS,
      maxVUs: INGEST_VUS,
      exec: 'ingest',
      startTime: '0s',
      tags: { phase: 'ingest', stream: stream.name },
    };
  }

  scenarios.query = {
    executor: 'constant-arrival-rate',
    rate: QUERY_RATE,
    timeUnit: '1s',
    duration: `${QUERY_DURATION_SECONDS}s`,
    preAllocatedVUs: QUERY_VUS,
    maxVUs: QUERY_VUS,
    exec: 'query',
    startTime: `${QUERY_START_SECONDS}s`,
    tags: { phase: 'query' },
  };

  return scenarios;
}

function buildThresholds() {
  const thresholds = {
    ldes_ingest_ms: [`p(95)<${INGEST_P95_MS}`],
    ldes_query_ms: [`p(95)<${QUERY_P95_MS}`],
    'http_req_failed{phase:ingest}': [`rate<${MAX_FAILED_RATE}`],
    'http_req_failed{phase:query}': [`rate<${MAX_FAILED_RATE}`],
  };

  for (const stream of catalog.streams) {
    thresholds[`ingest_failed_${metricName(stream.name, 'total')}`] = ['count==0'];
  }

  return thresholds;
}

function scenarioName(streamName) {
  return `ingest_${streamName.replace(/-/g, '_')}`;
}

const runtime = buildRuntime({});

const STREAM_BY_SCENARIO = {};
const INGEST_TARGET = {};
const STREAM_SEQUENCE_START = {};

for (const stream of catalog.streams) {
  STREAM_BY_SCENARIO[scenarioName(stream.name)] = stream;
  INGEST_TARGET[stream.name] = loadtestCount(stream);
  STREAM_SEQUENCE_START[stream.name] = SEQUENCE_OFFSET + seedCount(stream);
}

export function ingest() {
  const stream = STREAM_BY_SCENARIO[exec.scenario.name];
  const iteration = exec.scenario.iterationInTest;

  // A constant-arrival-rate scenario schedules `rate * duration` iterations, and the duration is
  // rounded up, so it can run past the configured number of members. Stopping here keeps the
  // number of ingested members exactly what was asked for, and keeps the generated sequence
  // numbers inside the range the timestamp stride was sized for.
  if (iteration >= INGEST_TARGET[stream.name]) {
    return;
  }

  // The seeding run owns sequence numbers 0..seedCount-1, so the load test continues after them.
  // Every sequence number is used exactly once, which makes the generated version IRIs unique
  // without any coordination between the virtual users. SEQUENCE_OFFSET shifts the whole range for
  // a repeat run against an environment that still holds the members of an earlier run.
  const sequence = STREAM_SEQUENCE_START[stream.name] + iteration;
  const generated = runtime.generator.build(stream.name, sequence);

  const response = http.post(ingestUrl(stream.name), generated.body, {
    headers: { 'Content-Type': 'text/turtle' },
    timeout: REQUEST_TIMEOUT,
    tags: { name: `ingest:${stream.name}`, phase: 'ingest', stream: stream.name },
  });

  ingestDuration.add(response.timings.duration);
  ingestTrend[stream.name].add(response.timings.duration);

  check(response, {
    'member accepted': (r) => r.status === 201,
  });

  if (response.status === 201) {
    ingested[stream.name].add(1);
    totalIngested.add(1);
  } else if (response.status === 200) {
    duplicated[stream.name].add(1);
  } else {
    ingestFailed[stream.name].add(1);
    if (iteration < 5) {
      console.error(`ingest ${stream.name} failed with ${response.status}: ${String(response.body).slice(0, 500)}`);
    }
  }
}

export function query() {
  const target = TARGETS[exec.scenario.iterationInTest % TARGETS.length];

  const response = http.get(target.url, {
    headers: { Accept: 'text/turtle' },
    timeout: REQUEST_TIMEOUT,
    tags: { name: `view:${target.key}`, phase: 'query', view: target.key },
  });

  record(target, response);

  const ok = check(response, {
    'view served': (r) => r.status === 200,
    'view is a TREE node': (r) => typeof r.body === 'string' && r.body.indexOf('tree') !== -1,
  });

  if (!ok) {
    return;
  }

  // Following a relation is what a real client does, and it is the only way to reach the
  // geospatial tiles and the time buckets without knowing their identifiers up front.
  const relations = relationsOf(response.body);
  if (relations.length === 0) {
    return;
  }

  const fragment = relations[Math.floor(Math.random() * relations.length)];
  const fragmentResponse = http.get(fragment, {
    headers: { Accept: 'text/turtle' },
    timeout: REQUEST_TIMEOUT,
    tags: { name: `fragment:${target.key}`, phase: 'query', view: target.key },
  });

  fragmentsFollowed.add(1);
  record(target, fragmentResponse);

  check(fragmentResponse, {
    'fragment served': (r) => r.status === 200,
  });
}

function record(target, response) {
  queryDuration.add(response.timings.duration);
  queryTrend[target.key].add(response.timings.duration);
  queryCount[target.key].add(1);
  totalQueries.add(1);

  if (response.status !== 200) {
    queryFailed[target.key].add(1);
  }
}

const RELATION_PATTERN = /(?:tree:node|<https:\/\/w3id\.org\/tree#node>)\s+<([^>]+)>/g;

function relationsOf(body) {
  if (typeof body !== 'string') {
    return [];
  }

  const found = [];
  let match;
  RELATION_PATTERN.lastIndex = 0;
  while ((match = RELATION_PATTERN.exec(body)) !== null) {
    found.push(match[1]);
  }
  return found;
}

export function handleSummary(data) {
  const durationMs = (data.state && data.state.testRunDurationMs) || 0;
  const finishedAt = new Date();
  const startedAt = new Date(finishedAt.getTime() - durationMs);

  const streams = {};
  for (const stream of catalog.streams) {
    const key = metricName(stream.name, 'total');
    streams[stream.name] = {
      target: loadtestCount(stream),
      targetRatePerSecond: loadtestRate(stream),
      ingested: value(data, `ingested_${key}`, 'count'),
      duplicates: value(data, `duplicate_${key}`, 'count'),
      failed: value(data, `ingest_failed_${key}`, 'count'),
      avgMs: value(data, `ingest_ms_${key}`, 'avg'),
      p95Ms: value(data, `ingest_ms_${key}`, 'p(95)'),
      maxMs: value(data, `ingest_ms_${key}`, 'max'),
    };
  }

  const views = {};
  for (const target of TARGETS) {
    views[target.key] = {
      stream: target.stream,
      view: target.view,
      kind: target.kind,
      requests: value(data, `query_count_${target.metric}`, 'count'),
      failed: value(data, `query_failed_${target.metric}`, 'count'),
      avgMs: value(data, `query_ms_${target.metric}`, 'avg'),
      p95Ms: value(data, `query_ms_${target.metric}`, 'p(95)'),
      maxMs: value(data, `query_ms_${target.metric}`, 'max'),
    };
  }

  const metrics = {
    phase: 'loadtest',
    startedAt: startedAt.toISOString(),
    finishedAt: finishedAt.toISOString(),
    durationSeconds: Math.round(durationMs / 1000),
    configuration: {
      ingestVus: INGEST_VUS,
      queryVus: QUERY_VUS,
      queryRatePerSecond: QUERY_RATE,
      ingestPhaseSeconds: INGEST_PHASE_SECONDS,
      settleSeconds: SETTLE_SECONDS,
      queryDurationSeconds: QUERY_DURATION_SECONDS,
    },
    totals: {
      membersIngested: value(data, 'ldes_members_ingested', 'count'),
      queries: value(data, 'ldes_queries', 'count'),
      fragmentsFollowed: value(data, 'ldes_fragments_followed', 'count'),
      droppedIterations: value(data, 'dropped_iterations', 'count'),
      ingestP95Ms: value(data, 'ldes_ingest_ms', 'p(95)'),
      ingestAvgMs: value(data, 'ldes_ingest_ms', 'avg'),
      queryP95Ms: value(data, 'ldes_query_ms', 'p(95)'),
      queryAvgMs: value(data, 'ldes_query_ms', 'avg'),
      queryMaxMs: value(data, 'ldes_query_ms', 'max'),
      httpFailedRate: value(data, 'http_req_failed', 'rate'),
    },
    thresholds: thresholdResults(data),
    streams,
    views,
  };

  return {
    'loadtest-summary.json': JSON.stringify(data, null, 2),
    'loadtest-metrics.json': JSON.stringify(metrics, null, 2),
    'loadtest-summary.md': markdown(metrics),
    stdout: text(metrics),
  };
}

function value(data, name, field) {
  const metric = data.metrics[name];
  if (!metric || !metric.values || metric.values[field] === undefined) {
    return field === 'count' ? 0 : null;
  }
  return round(metric.values[field]);
}

function round(number) {
  return typeof number === 'number' ? Math.round(number * 100) / 100 : number;
}

function thresholdResults(data) {
  const results = [];
  for (const name of Object.keys(data.metrics)) {
    const metric = data.metrics[name];
    if (!metric.thresholds) {
      continue;
    }
    for (const expression of Object.keys(metric.thresholds)) {
      results.push({ metric: name, expression, ok: metric.thresholds[expression].ok === true });
    }
  }
  return results;
}

function ms(number) {
  return number === null ? 'n/a' : `${number} ms`;
}

function markdown(metrics) {
  const lines = [
    '### Load test',
    '',
    `Ingested **${metrics.totals.membersIngested}** members and made **${metrics.totals.queries}** view requests in ${metrics.durationSeconds}s ` +
      `(${metrics.configuration.ingestVus} publishing user(s) per stream, ${metrics.configuration.queryVus} querying users).`,
    '',
    '| Stream | Target | Ingested | Duplicates | Failed | avg | p95 | max |',
    '| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |',
  ];

  for (const name of Object.keys(metrics.streams)) {
    const s = metrics.streams[name];
    lines.push(
      `| \`${name}\` | ${s.target} | ${s.ingested} | ${s.duplicates} | ${s.failed} | ${ms(s.avgMs)} | ${ms(s.p95Ms)} | ${ms(s.maxMs)} |`,
    );
  }

  lines.push('', '| View | Kind | Requests | Failed | avg | p95 | max |', '| --- | --- | ---: | ---: | ---: | ---: | ---: |');

  for (const key of Object.keys(metrics.views)) {
    const v = metrics.views[key];
    lines.push(`| \`${key}\` | ${v.kind} | ${v.requests} | ${v.failed} | ${ms(v.avgMs)} | ${ms(v.p95Ms)} | ${ms(v.maxMs)} |`);
  }

  lines.push('');
  return lines.join('\n');
}

function text(metrics) {
  return [
    '',
    'LDES load test',
    '--------------',
    `members ingested : ${metrics.totals.membersIngested}`,
    `queries          : ${metrics.totals.queries} (${metrics.totals.fragmentsFollowed} fragments followed)`,
    `ingest p95       : ${ms(metrics.totals.ingestP95Ms)}`,
    `query p95        : ${ms(metrics.totals.queryP95Ms)}`,
    `dropped          : ${metrics.totals.droppedIterations}`,
    '',
  ].join('\n');
}
