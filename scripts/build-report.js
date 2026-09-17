#!/usr/bin/env node
'use strict';

/**
 * Combines everything the run produced into one report and decides whether the run passed.
 *
 * Inputs:
 *   catalog/streams.json            the streams, views and sink tables that were expected
 *   loadtest/seed-summary.json      the realistic basis that was ingested up front
 *   loadtest/loadtest-metrics.json  ingest and query metrics per stream and per view
 *   reports/replication.json        how long LDIO needed to catch up
 *   reports/postgres-counts.json    row counts and replication timestamps per table
 *   reports/postgres-checks.json    the data quality checks
 *
 * The run fails when a data quality check fails, when the replication did not complete, when the
 * report itself is inconsistent, or when one of the configurable time metrics is breached.
 *
 * Usage:
 *   node scripts/build-report.js --out report.md --json reports/report.json
 */

const fs = require('fs');
const path = require('path');

const THRESHOLDS = {
  maxIngestP95Ms: number(process.env.MAX_INGEST_P95_MS, 2000),
  maxIngestMaxMs: number(process.env.MAX_INGEST_MAX_MS, 15000),
  maxQueryP95Ms: number(process.env.MAX_QUERY_P95_MS, 3000),
  maxQueryMaxMs: number(process.env.MAX_QUERY_MAX_MS, 15000),
  maxViewP95Ms: number(process.env.MAX_VIEW_P95_MS, 5000),
  maxReplicationSeconds: number(process.env.MAX_REPLICATION_SECONDS, 600),
  minIngestCompletion: number(process.env.MIN_INGEST_COMPLETION, 0.95),
  maxIngestFailures: number(process.env.MAX_INGEST_FAILURES, 0),
  maxQueryFailures: number(process.env.MAX_QUERY_FAILURES, 0),
  minQueriesPerView: number(process.env.MIN_QUERIES_PER_VIEW, 1),
};

function number(value, fallback) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function parseArguments(argv) {
  const options = {
    catalog: 'catalog/streams.json',
    seed: 'loadtest/seed-summary.json',
    loadtest: 'loadtest/loadtest-metrics.json',
    replication: 'reports/replication.json',
    counts: 'reports/postgres-counts.json',
    checks: 'reports/postgres-checks.json',
    out: 'report.md',
    json: 'reports/report.json',
    environment: process.env.ENVIRONMENT_NAME || 'local',
    serverUrl: process.env.LDES_SERVER_URL || '',
  };

  for (let i = 2; i < argv.length; i += 2) {
    const key = argv[i].replace(/^--/, '').replace(/-([a-z])/g, (_, c) => c.toUpperCase());
    options[key] = argv[i + 1];
  }

  return options;
}

function readJson(file, fallback) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (error) {
    if (fallback !== undefined) {
      return fallback;
    }
    throw new Error(`Cannot read ${file}: ${error.message}`);
  }
}

function main() {
  const options = parseArguments(process.argv);

  const catalog = readJson(options.catalog);
  const seed = readJson(options.seed, { streams: {}, totalCreated: 0 });
  const loadtest = readJson(options.loadtest, null);
  const replication = readJson(options.replication, { status: 'missing', waitedSeconds: null });
  const counts = readJson(options.counts, {});
  const checks = readJson(options.checks, []);

  const failures = [];
  const warnings = [];

  if (!loadtest) {
    failures.push('The load test produced no metrics, so nothing could be verified.');
  }

  const consistency = validateReport({ catalog, seed, loadtest, counts, checks, failures, warnings });
  const timing = evaluateTiming({ loadtest, counts, replication, failures });
  const quality = evaluateQuality({ checks, replication, failures });

  const report = {
    environment: options.environment,
    generatedAt: new Date().toISOString(),
    passed: failures.length === 0,
    failures,
    warnings,
    thresholds: THRESHOLDS,
    seed,
    loadtest,
    replication,
    counts,
    quality,
    timing,
    consistency,
  };

  const markdown = renderMarkdown(report, catalog, options);

  fs.mkdirSync(path.dirname(path.resolve(options.out)), { recursive: true });
  fs.writeFileSync(options.out, markdown);

  fs.mkdirSync(path.dirname(path.resolve(options.json)), { recursive: true });
  fs.writeFileSync(options.json, JSON.stringify(report, null, 2));

  process.stdout.write(markdown);

  if (!report.passed) {
    process.stderr.write(`\n${failures.length} problem(s) found:\n- ${failures.join('\n- ')}\n`);
    process.exit(1);
  }
}

/**
 * Validates the report itself: every stream of the catalogue has to be covered by the load test,
 * by the row counts and by the checks, and the numbers the three of them report have to agree.
 * Without this a silently skipped stream would produce a green report.
 */
function validateReport({ catalog, seed, loadtest, counts, checks, failures, warnings }) {
  const covered = { streams: [], views: [], tables: [] };
  const checkedTables = new Set(checks.map((entry) => entry.table));

  for (const stream of catalog.streams) {
    const table = stream.sink.table;
    covered.streams.push(stream.name);
    covered.tables.push(table);

    const seeded = (seed.streams || {})[stream.name];
    if (!seeded) {
      failures.push(`The seeding run did not cover \`${stream.name}\`.`);
    } else if (seeded.created !== seeded.requested) {
      failures.push(`Seeding \`${stream.name}\` created ${seeded.created} of ${seeded.requested} members.`);
    }

    const ingest = loadtest && loadtest.streams ? loadtest.streams[stream.name] : null;
    if (!ingest) {
      failures.push(`The load test did not cover \`${stream.name}\`.`);
    }

    const count = counts[table];
    if (!count) {
      failures.push(`No row count was reported for \`${table}\`.`);
    } else if (ingest && seeded) {
      const expected = seeded.created + ingest.ingested;
      if (count.expected_rows !== expected) {
        failures.push(
          `The expectation used for \`${table}\` (${count.expected_rows}) does not match what was ingested (${expected}).`,
        );
      }
      if (count.rows !== expected) {
        failures.push(`\`${table}\` holds ${count.rows} rows, expected ${expected}.`);
      }
    }

    if (!checkedTables.has(table)) {
      failures.push(`No data quality checks ran against \`${table}\`.`);
    }

    for (const view of stream.views) {
      const key = `${stream.name}/${view.name}`;
      covered.views.push(key);

      const measured = loadtest && loadtest.views ? loadtest.views[key] : null;
      if (!measured) {
        failures.push(`View \`${key}\` was never queried.`);
      } else if (measured.requests < THRESHOLDS.minQueriesPerView) {
        failures.push(`View \`${key}\` received ${measured.requests} requests, expected at least ${THRESHOLDS.minQueriesPerView}.`);
      }
    }
  }

  if (loadtest && loadtest.streams) {
    const summed = Object.keys(loadtest.streams).reduce((total, name) => total + loadtest.streams[name].ingested, 0);
    if (summed !== loadtest.totals.membersIngested) {
      failures.push(`The per stream ingest counts add up to ${summed}, but the total says ${loadtest.totals.membersIngested}.`);
    }

    for (const name of Object.keys(loadtest.streams)) {
      const stream = loadtest.streams[name];
      const completion = stream.target === 0 ? 1 : stream.ingested / stream.target;
      if (completion < THRESHOLDS.minIngestCompletion) {
        failures.push(
          `Only ${stream.ingested} of the ${stream.target} members of \`${name}\` were ingested ` +
            `(${(completion * 100).toFixed(1)}%, minimum ${(THRESHOLDS.minIngestCompletion * 100).toFixed(0)}%).`,
        );
      }
      if (stream.duplicates > 0) {
        warnings.push(`\`${name}\` produced ${stream.duplicates} duplicate member identifiers, which the server ignored.`);
      }
    }

    if (loadtest.totals.droppedIterations > 0) {
      warnings.push(
        `k6 dropped ${loadtest.totals.droppedIterations} iterations: the configured publishing users could not sustain the requested rate.`,
      );
    }
  }

  return covered;
}

function evaluateTiming({ loadtest, counts, replication, failures }) {
  if (!loadtest) {
    return [];
  }

  const lastIngestedAt = Object.keys(counts)
    .map((table) => counts[table] && counts[table].last_ingested_at)
    .filter(Boolean)
    .map((value) => Date.parse(value))
    .filter((value) => Number.isFinite(value));

  const replicationSeconds =
    lastIngestedAt.length > 0
      ? Math.max(0, Math.round((Math.max(...lastIngestedAt) - Date.parse(loadtest.finishedAt)) / 1000))
      : null;

  const metrics = [
    metric('Ingest p95', loadtest.totals.ingestP95Ms, THRESHOLDS.maxIngestP95Ms, 'ms'),
    metric('Ingest max', maxOf(loadtest.streams, 'maxMs'), THRESHOLDS.maxIngestMaxMs, 'ms'),
    metric('Query p95', loadtest.totals.queryP95Ms, THRESHOLDS.maxQueryP95Ms, 'ms'),
    metric('Query max', loadtest.totals.queryMaxMs, THRESHOLDS.maxQueryMaxMs, 'ms'),
    metric('Slowest view p95', maxOf(loadtest.views, 'p95Ms'), THRESHOLDS.maxViewP95Ms, 'ms'),
    metric('Replication completed after load test', replicationSeconds, THRESHOLDS.maxReplicationSeconds, 's'),
    metric('Failed ingest requests', sumOf(loadtest.streams, 'failed'), THRESHOLDS.maxIngestFailures, ''),
    metric('Failed view requests', sumOf(loadtest.views, 'failed'), THRESHOLDS.maxQueryFailures, ''),
  ];

  for (const entry of metrics) {
    if (entry.ok === false) {
      failures.push(`${entry.name} is ${entry.value}${entry.unit}, above the configured maximum of ${entry.threshold}${entry.unit}.`);
    }
    if (entry.value === null) {
      failures.push(`${entry.name} could not be measured.`);
    }
  }

  // Wall clock information that is reported but not gated.
  metrics.push({
    name: 'LDIO catch-up wait',
    value: replication.waitedSeconds,
    threshold: null,
    unit: 's',
    ok: null,
  });

  return metrics;
}

function metric(name, value, threshold, unit) {
  return {
    name,
    value,
    threshold,
    unit,
    ok: value === null ? null : value <= threshold,
  };
}

function maxOf(collection, field) {
  const values = Object.keys(collection || {})
    .map((key) => collection[key][field])
    .filter((value) => typeof value === 'number');
  return values.length > 0 ? Math.max(...values) : null;
}

function sumOf(collection, field) {
  return Object.keys(collection || {}).reduce((total, key) => total + (collection[key][field] || 0), 0);
}

function evaluateQuality({ checks, replication, failures }) {
  const failed = checks.filter((entry) => entry.ok !== true);

  for (const entry of failed) {
    failures.push(`Data quality check \`${entry.table}.${entry.check}\` failed: expected ${entry.expected}, got ${entry.actual}.`);
  }

  if (replication.status !== 'ready') {
    failures.push(`LDIO did not replicate every member into PostgreSQL (status: ${replication.status}).`);
  }

  return { total: checks.length, failed: failed.length, failures: failed };
}

function renderMarkdown(report, catalog, options) {
  const lines = [];
  const loadtest = report.loadtest;

  lines.push(`## LDES test environment \`${report.environment}\` — ${report.passed ? '✅ passed' : '❌ failed'}`);
  lines.push('');

  if (options.serverUrl) {
    lines.push(`LDES server: ${options.serverUrl}`);
    lines.push('');
  }

  lines.push(
    `${catalog.streams.length} event streams, ` +
      `${catalog.streams.reduce((total, stream) => total + stream.views.length, 0)} views, ` +
      `${report.seed.totalCreated || 0} seeded reference members.`,
  );
  lines.push('');

  if (!report.passed) {
    lines.push('### Problems');
    lines.push('');
    for (const failure of report.failures) {
      lines.push(`- ❌ ${failure}`);
    }
    lines.push('');
  }

  if (report.warnings.length > 0) {
    lines.push('### Warnings');
    lines.push('');
    for (const warning of report.warnings) {
      lines.push(`- ⚠️ ${warning}`);
    }
    lines.push('');
  }

  if (loadtest) {
    lines.push('### Ingestion');
    lines.push('');
    lines.push('| Stream | Seeded | Target | Ingested | Rate | Rows in PostgreSQL | Distinct members | p95 | max |');
    lines.push('| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |');

    for (const stream of catalog.streams) {
      const table = stream.sink.table;
      const ingest = loadtest.streams[stream.name] || {};
      const seeded = (report.seed.streams || {})[stream.name] || {};
      const count = report.counts[table] || {};

      lines.push(
        `| \`${stream.name}\` (${stream.complexity}) | ${seeded.created || 0} | ${ingest.target || 0} | ${ingest.ingested || 0} ` +
          `| ${ingest.targetRatePerSecond || 0}/s | ${count.rows !== undefined ? count.rows : 'n/a'} ` +
          `| ${count.distinct_members !== undefined ? count.distinct_members : 'n/a'} ` +
          `| ${format(ingest.p95Ms, 'ms')} | ${format(ingest.maxMs, 'ms')} |`,
      );
    }

    lines.push('');
    lines.push('### Views');
    lines.push('');
    lines.push('| View | Fragmentation | Requests | Failed | avg | p95 | max |');
    lines.push('| --- | --- | ---: | ---: | ---: | ---: | ---: |');

    for (const key of Object.keys(loadtest.views)) {
      const view = loadtest.views[key];
      lines.push(
        `| \`${key}\` | ${view.kind} | ${view.requests} | ${view.failed} | ${format(view.avgMs, 'ms')} | ${format(view.p95Ms, 'ms')} | ${format(view.maxMs, 'ms')} |`,
      );
    }

    lines.push('');
  }

  lines.push('### Time metrics');
  lines.push('');
  lines.push('| Metric | Value | Threshold | |');
  lines.push('| --- | ---: | ---: | :-: |');

  for (const entry of report.timing) {
    const status = entry.ok === null ? '—' : entry.ok ? '✅' : '❌';
    const threshold = entry.threshold === null ? 'n/a' : format(entry.threshold, entry.unit);
    lines.push(`| ${entry.name} | ${format(entry.value, entry.unit)} | ${threshold} | ${status} |`);
  }

  lines.push('');
  lines.push('### Data quality');
  lines.push('');
  lines.push(
    `${report.quality.total - report.quality.failed} of ${report.quality.total} checks passed ` +
      `(row counts, distinct members, version identity, referential integrity between the streams, ` +
      `value ranges, enumerations, identifier patterns and WKT geometries).`,
  );
  lines.push('');

  if (report.quality.failed > 0) {
    lines.push('| Table | Check | Expected | Actual |');
    lines.push('| --- | --- | ---: | ---: |');
    for (const entry of report.quality.failures) {
      lines.push(`| \`${entry.table}\` | \`${entry.check}\` | ${entry.expected} | ${entry.actual} |`);
    }
    lines.push('');
  }

  return lines.join('\n') + '\n';
}

function format(value, unit) {
  if (value === null || value === undefined) {
    return 'n/a';
  }
  return `${value}${unit ? ' ' + unit : ''}`;
}

main();
