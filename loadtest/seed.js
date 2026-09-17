import http from 'k6/http';
import { Counter } from 'k6/metrics';

import {
  catalog,
  buildRuntime,
  ingestUrl,
  seedCount,
  metricName,
  REQUEST_TIMEOUT,
} from './lib/config.js';

/**
 * Ingests the realistic basis every other member refers to.
 *
 * The monitoring stations, water bodies and sensors published here are the only members the
 * complex streams ever reference, which is what makes the referential integrity checks on the
 * PostgreSQL sink meaningful: every foreign key must resolve to a member that was seeded.
 *
 * Run this once, before the load test:
 *
 *   LDES_SERVER_URL=http://pr-12.203-0-113-45.nip.io k6 run seed.js
 */

const created = {};
const duplicates = {};
const failures = {};

for (const stream of catalog.streams) {
  created[stream.name] = new Counter(`seed_created_${metricName(stream.name, 'total')}`);
  duplicates[stream.name] = new Counter(`seed_duplicate_${metricName(stream.name, 'total')}`);
  failures[stream.name] = new Counter(`seed_failed_${metricName(stream.name, 'total')}`);
}

export const options = {
  // The error path logs the response body, and the seeding run is small enough that keeping the
  // bodies costs nothing.
  discardResponseBodies: false,
  scenarios: {
    seed: {
      executor: 'shared-iterations',
      vus: 1,
      iterations: 1,
      maxDuration: __ENV.SEED_MAX_DURATION || '15m',
    },
  },
  thresholds: Object.assign(
    {},
    ...catalog.streams.map((stream) => ({
      [`seed_failed_${metricName(stream.name, 'total')}`]: ['count==0'],
      [`seed_duplicate_${metricName(stream.name, 'total')}`]: ['count==0'],
    })),
  ),
};

const runtime = buildRuntime({});

export default function seed() {
  // Ordered so that the members referenced most often exist first. The references are circular
  // between the complex streams, so this is a readability choice rather than a requirement: the
  // LDES server does not resolve references, and the checks only run once everything is ingested.
  const order = [
    'water-level-measurements',
    'air-quality-observations',
    'water-sensors',
    'water-bodies',
    'monitoring-stations',
    'pollution-incidents',
  ];

  for (const name of order) {
    const stream = catalog.streams.find((candidate) => candidate.name === name);
    const total = seedCount(stream);

    for (let sequence = 0; sequence < total; sequence++) {
      post(stream, sequence);
    }
  }
}

function post(stream, sequence) {
  const generated = runtime.generator.build(stream.name, sequence);

  const response = http.post(ingestUrl(stream.name), generated.body, {
    headers: { 'Content-Type': 'text/turtle' },
    timeout: REQUEST_TIMEOUT,
    tags: { name: `seed:${stream.name}` },
  });

  if (response.status === 201) {
    created[stream.name].add(1);
  } else if (response.status === 200) {
    // The LDES server answers 200 when it already knows the member subject; for a fresh
    // environment that always indicates a bug in the identifier generation.
    duplicates[stream.name].add(1);
  } else {
    failures[stream.name].add(1);
    console.error(`seed ${stream.name}#${sequence} failed with ${response.status}: ${String(response.body).slice(0, 400)}`);
  }
}

export function handleSummary(data) {
  const streams = {};
  let total = 0;

  for (const stream of catalog.streams) {
    const suffix = metricName(stream.name, 'total');
    const entry = {
      requested: seedCount(stream),
      created: count(data, `seed_created_${suffix}`),
      duplicates: count(data, `seed_duplicate_${suffix}`),
      failed: count(data, `seed_failed_${suffix}`),
    };
    streams[stream.name] = entry;
    total += entry.created;
  }

  const summary = { phase: 'seed', generatedAt: new Date().toISOString(), totalCreated: total, streams };

  return {
    'seed-summary.json': JSON.stringify(summary, null, 2),
    stdout: `\nSeeded ${total} members\n${JSON.stringify(streams, null, 2)}\n`,
  };
}

function count(data, name) {
  const metric = data.metrics[name];
  return metric && metric.values && metric.values.count ? metric.values.count : 0;
}
