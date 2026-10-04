import { buildReferenceData } from './reference-data.js';
import { createGenerator } from './members.js';

/**
 * Resolves the run configuration.
 *
 * catalog/streams.json holds the defaults for every stream; each of them can be overridden with an
 * environment variable so the workflow can drive the run from repository variables. The variable
 * names are derived from the stream name, for example:
 *
 *   LT_AIR_QUALITY_OBSERVATIONS_MEMBERS=10000
 *   LT_AIR_QUALITY_OBSERVATIONS_RATE=40
 *
 * The catalogue is read with open(), which k6 resolves relative to this file.
 */

export const catalog = JSON.parse(open('../../catalog/streams.json'));

export const LDES_SERVER_URL = requireEnv('LDES_SERVER_URL');

/** Multiplies every member count. Handy to smoke test the whole chain in a few seconds. */
export const MEMBER_SCALE = numberEnv('MEMBER_SCALE', 1);

/**
 * Multiplies every publishing rate.
 *
 * Scaling the member counts on their own only makes the ingest phase longer, and it runs into
 * INGEST_MAX_DURATION_SECONDS long before the extra members are published: at MEMBER_SCALE=20 every
 * stream needs an hour at its catalogue rate, so the 600 second cap truncates the run to a twentieth
 * of the target. Scaling the rates alongside the counts keeps the ingest phase the same length and
 * makes MEMBER_SCALE a multiplier of the load rather than of the run time.
 *
 * Scaling down works the other way around: a smoke run should be shorter, not slower, so the rates
 * stay at their catalogue values below scale 1. Set RATE_SCALE explicitly to decouple the two.
 */
export const RATE_SCALE = numberEnv('RATE_SCALE', Math.max(1, MEMBER_SCALE));

export const INGEST_VUS = intEnv('INGEST_VUS', 1);
export const INGEST_MAX_DURATION_SECONDS = intEnv('INGEST_MAX_DURATION_SECONDS', 600);

export const QUERY_VUS = intEnv('QUERY_VUS', 10);
export const QUERY_RATE = intEnv('QUERY_RATE', 20);
export const QUERY_DURATION_SECONDS = intEnv('QUERY_DURATION_SECONDS', 120);

/**
 * The LDES server fragments asynchronously (`fragmentationCron`, every 30 seconds by default), so
 * members ingested at the very end of the ingest phase are not in a fragment yet. Waiting before
 * the query phase starts measures the views rather than the fragmentation backlog.
 */
export const SETTLE_SECONDS = intEnv('SETTLE_SECONDS', 45);

export const HISTORY_DAYS = intEnv('HISTORY_DAYS', 7);

/**
 * Shifts every sequence number, and with it every generated member IRI and timestamp.
 *
 * A run normally owns the sequence numbers right after the seeding run, which keeps the member IRIs
 * unique for a freshly created environment. Publishing a second time into an environment that still
 * holds the members of an earlier run would reuse those IRIs, so such a repeat run sets this to a
 * number beyond everything the earlier run used.
 */
export const SEQUENCE_OFFSET = intEnv('SEQUENCE_OFFSET', 0);

export const REQUEST_TIMEOUT = __ENV.REQUEST_TIMEOUT || '60s';

export function envKey(streamName) {
  return streamName.toUpperCase().replace(/-/g, '_');
}

export function seedCount(stream) {
  return Math.max(1, Math.round(stream.seed.members * MEMBER_SCALE));
}

export function loadtestCount(stream) {
  const key = envKey(stream.name);
  const configured = intEnv(`LT_${key}_MEMBERS`, stream.loadtest.members);
  return Math.max(0, Math.round(configured * MEMBER_SCALE));
}

export function loadtestRate(stream) {
  const key = envKey(stream.name);
  const configured = intEnv(`LT_${key}_RATE`, stream.loadtest.membersPerSecond);
  return Math.max(1, Math.round(configured * RATE_SCALE));
}

/** Publishing users a stream needs to sustain its rate, given how long a request takes. */
export function requiredVus(stream, requestMs) {
  return Math.ceil((loadtestRate(stream) * requestMs) / 1000);
}

/** Seconds the stream needs to publish its members at the configured rate, capped. */
export function ingestSeconds(stream) {
  const seconds = Math.ceil(loadtestCount(stream) / loadtestRate(stream));
  return Math.max(1, Math.min(seconds, INGEST_MAX_DURATION_SECONDS));
}

export function ingestPhaseSeconds() {
  return catalog.streams.reduce((longest, stream) => Math.max(longest, ingestSeconds(stream)), 1);
}

export function referenceCounts() {
  const counts = {};
  for (const stream of catalog.streams) {
    counts[stream.name] = seedCount(stream);
  }

  return {
    waterBodies: counts['water-bodies'],
    monitoringStations: counts['monitoring-stations'],
    waterSensors: counts['water-sensors'],
    airQualityObservations: counts['air-quality-observations'],
    waterLevelMeasurements: counts['water-level-measurements'],
    pollutionIncidents: counts['pollution-incidents'],
  };
}

export function buildRuntime(options) {
  const reference = buildReferenceData(referenceCounts());

  const expectedMembers = {};
  for (const stream of catalog.streams) {
    expectedMembers[stream.name] = seedCount(stream) + loadtestCount(stream);
  }

  const generator = createGenerator(catalog, reference, {
    historyDays: HISTORY_DAYS,
    expectedMembers,
    endMs: (options && options.endMs) || Date.now(),
  });

  return { reference, generator, expectedMembers };
}

export function ingestUrl(streamName) {
  return `${LDES_SERVER_URL}/${streamName}`;
}

export function viewUrl(streamName, viewName) {
  return `${LDES_SERVER_URL}/${streamName}/${viewName}`;
}

/** Every view of every stream, flattened into the list the query phase walks over. */
export function queryTargets() {
  const targets = [];
  for (const stream of catalog.streams) {
    for (const view of stream.views) {
      targets.push({
        stream: stream.name,
        view: view.name,
        kind: view.kind,
        key: `${stream.name}/${view.name}`,
        metric: metricName(stream.name, view.name),
        url: viewUrl(stream.name, view.name),
      });
    }
  }
  return targets;
}

export function metricName(streamName, suffix) {
  return `${streamName}_${suffix}`.replace(/[^a-zA-Z0-9_]/g, '_');
}

function requireEnv(name) {
  const value = __ENV[name];
  if (!value) {
    throw new Error(`Missing required environment variable ${name}`);
  }
  return value.replace(/\/+$/, '');
}

function intEnv(name, fallback) {
  const value = parseInt(__ENV[name], 10);
  return Number.isNaN(value) ? fallback : value;
}

function numberEnv(name, fallback) {
  const value = parseFloat(__ENV[name]);
  return Number.isNaN(value) ? fallback : value;
}
