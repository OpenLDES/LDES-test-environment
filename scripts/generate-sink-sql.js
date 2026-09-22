#!/usr/bin/env node
'use strict';

/**
 * Generates the SQL that verifies what LDIO wrote into PostgreSQL.
 *
 * Three files are produced, all derived from catalog/streams.json plus the two summaries the k6
 * runs wrote, so that adding a column or a stream to the catalogue automatically extends the
 * verification:
 *
 *   wait.sql    returns `ready` once every table holds the number of rows that were ingested;
 *   counts.sql  returns per table row counts and replication timestamps as JSON;
 *   checks.sql  returns one JSON object per data quality check.
 *
 * Usage:
 *   node scripts/generate-sink-sql.js \
 *       --catalog catalog/streams.json \
 *       --seed loadtest/seed-summary.json \
 *       --loadtest loadtest/loadtest-metrics.json \
 *       --out reports/sql
 */

const fs = require('fs');
const path = require('path');

function parseArguments(argv) {
  const options = {
    catalog: 'catalog/streams.json',
    seed: 'loadtest/seed-summary.json',
    loadtest: 'loadtest/loadtest-metrics.json',
    out: 'reports/sql',
    maxAgeDays: '30',
  };

  for (let i = 2; i < argv.length; i += 2) {
    const key = argv[i].replace(/^--/, '').replace(/-([a-z])/g, (_, c) => c.toUpperCase());
    options[key] = argv[i + 1];
  }

  return options;
}

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

/** Rows that must be present per table, and how many distinct members they must describe. */
function expectations(catalog, seed, loadtest) {
  const result = {};

  for (const stream of catalog.streams) {
    const seeded = (seed.streams[stream.name] || {}).created || 0;
    const loaded = (loadtest.streams[stream.name] || {}).ingested || 0;

    result[stream.name] = {
      table: stream.sink.table,
      rows: seeded + loaded,
      // A versioned stream republishes the seeded members, so the number of distinct members
      // stays exactly the size of the reference pool. An append stream publishes every member
      // once, so its members and its rows must match.
      distinctMembers: stream.seed.versioned ? seeded : seeded + loaded,
      versioned: Boolean(stream.seed.versioned),
    };
  }

  return result;
}

const quote = (value) => `'${String(value).replace(/'/g, "''")}'`;

const IDENTIFIER = /^[a-z_][a-z0-9_]*$/;

/**
 * Table and column names are interpolated into the generated SQL unquoted, so they are checked
 * here as well as in the Terraform variable: both consumers read the same catalogue, and neither
 * should trust it blindly.
 */
function assertIdentifiers(catalog) {
  for (const stream of catalog.streams) {
    if (!IDENTIFIER.test(stream.sink.table)) {
      throw new Error(`${stream.name}: sink table "${stream.sink.table}" is not a plain lowercase identifier`);
    }
    for (const column of stream.sink.columns) {
      if (!IDENTIFIER.test(column.name)) {
        throw new Error(`${stream.sink.table}: column "${column.name}" is not a plain lowercase identifier`);
      }
    }
  }
}

function check(table, name, expression, expected, detail) {
  return [
    'SELECT',
    `    ${quote(table)} AS table_name,`,
    `    ${quote(name)} AS check_name,`,
    `    ${quote(expected)} AS expected,`,
    `    (${expression})::text AS actual,`,
    `    (${detail}) AS ok`,
  ].join('\n');
}

/** A check that counts offending rows: it passes when the count is zero. */
function violations(table, name, condition, description) {
  const expression = `SELECT count(*) FROM ${table} WHERE ${condition}`;
  return check(table, name, `(${expression})`, '0', `(${expression}) = 0`) + `\n    -- ${description}`;
}

function columnChecks(catalog, stream) {
  const table = stream.sink.table;
  const box = catalog.boundingBox;
  const statements = [];

  for (const column of stream.sink.columns) {
    const name = column.name;
    const type = catalog.types[column.type];

    // A property that is missing from a member makes the whole basic graph pattern fail, so the
    // member produces no row at all rather than a row with a hole. A null therefore means the
    // sink schema and the SPARQL projection disagree, which is worth failing on.
    statements.push(violations(table, `not_null.${name}`, `${name} IS NULL`, `${name} must always be written`));

    if (column.pattern) {
      statements.push(
        violations(table, `pattern.${name}`, `${name} !~ ${quote(column.pattern)}`, `${name} must match ${column.pattern}`),
      );
    }

    if (column.enum) {
      const values = column.enum.map(quote).join(', ');
      statements.push(violations(table, `enum.${name}`, `${name} NOT IN (${values})`, `${name} must be one of ${column.enum.join(', ')}`));
    }

    if (column.minLength) {
      statements.push(
        violations(table, `length.${name}`, `length(${name}) < ${column.minLength}`, `${name} must be at least ${column.minLength} characters`),
      );
    }

    if (column.minimum !== undefined || column.maximum !== undefined) {
      const bounds = [];
      if (column.minimum !== undefined) bounds.push(`${name} < ${column.minimum}`);
      if (column.maximum !== undefined) bounds.push(`${name} > ${column.maximum}`);
      statements.push(
        violations(table, `range.${name}`, bounds.join(' OR '), `${name} must be within [${column.minimum}, ${column.maximum}]`),
      );
    }

    if (column.type === 'date') {
      statements.push(
        violations(table, `date.${name}`, `${name} !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'`, `${name} must be an ISO date`),
      );
    }

    if (column.type === 'wktPoint') {
      const wktPattern = '^POINT \\(-?[0-9]+(\\.[0-9]+)? -?[0-9]+(\\.[0-9]+)?\\)$';
      statements.push(violations(table, `wkt.${name}`, `${name} !~ ${quote(wktPattern)}`, `${name} must be a WKT point`));

      const longitude = `split_part(substring(${name} from '^POINT \\((.*)\\)$'), ' ', 1)::double precision`;
      const latitude = `split_part(substring(${name} from '^POINT \\((.*)\\)$'), ' ', 2)::double precision`;
      statements.push(
        violations(
          table,
          `bounds.${name}`,
          `${name} ~ ${quote(wktPattern)} AND (${longitude} NOT BETWEEN ${box.minLongitude} AND ${box.maxLongitude}` +
            ` OR ${latitude} NOT BETWEEN ${box.minLatitude} AND ${box.maxLatitude})`,
          `${name} must fall inside the configured bounding box`,
        ),
      );
    }

    if (column.references) {
      const target = catalog.streams.find((candidate) => candidate.name === column.references);
      if (!target) {
        throw new Error(`${stream.name}.${name} references unknown stream ${column.references}`);
      }
      statements.push(
        violations(
          table,
          `references.${name}`,
          `NOT EXISTS (SELECT 1 FROM ${target.sink.table} target WHERE target.member_id = ${table}.${name})`,
          `${name} must point at a member of ${target.sink.table}`,
        ),
      );
    }

    if (column.role === 'timestamp') {
      statements.push(
        violations(table, `future.${name}`, `${name} > now() + interval '5 minutes'`, `${name} must not lie in the future`),
      );
    }

    if (type.sql === 'timestamptz' && column.role !== 'timestamp') {
      statements.push(
        violations(table, `future.${name}`, `${name} > now() + interval '5 minutes'`, `${name} must not lie in the future`),
      );
    }
  }

  return statements;
}

function tableChecks(catalog, stream, expectation, maxAgeDays) {
  const table = stream.sink.table;

  const statements = [
    check(table, 'row_count', `SELECT count(*) FROM ${table}`, String(expectation.rows), `(SELECT count(*) FROM ${table}) = ${expectation.rows}`),
    check(
      table,
      'distinct_members',
      `SELECT count(DISTINCT member_id) FROM ${table}`,
      String(expectation.distinctMembers),
      `(SELECT count(DISTINCT member_id) FROM ${table}) = ${expectation.distinctMembers}`,
    ),
    check(
      table,
      'unique_versions',
      `SELECT count(DISTINCT version_id) FROM ${table}`,
      String(expectation.rows),
      `(SELECT count(DISTINCT version_id) FROM ${table}) = (SELECT count(*) FROM ${table})`,
    ),
    check(
      table,
      'version_belongs_to_member',
      `SELECT count(*) FROM ${table} WHERE position(member_id in version_id) <> 1`,
      '0',
      `(SELECT count(*) FROM ${table} WHERE position(member_id in version_id) <> 1) = 0`,
    ),
    violations(table, 'member_age', `created_at < now() - interval '${Number(maxAgeDays)} days'`, `created_at must be recent`),
  ];

  if (!expectation.versioned) {
    statements.push(
      check(
        table,
        'one_version_per_member',
        `SELECT count(*) FROM (SELECT member_id FROM ${table} GROUP BY member_id HAVING count(*) > 1) duplicates`,
        '0',
        `(SELECT count(*) FROM (SELECT member_id FROM ${table} GROUP BY member_id HAVING count(*) > 1) duplicates) = 0`,
      ),
    );
  }

  return statements.concat(columnChecks(catalog, stream));
}

function main() {
  const options = parseArguments(process.argv);
  const catalog = readJson(options.catalog);
  assertIdentifiers(catalog);
  const seed = readJson(options.seed);
  const loadtest = readJson(options.loadtest);
  const expected = expectations(catalog, seed, loadtest);

  const checks = [];
  for (const stream of catalog.streams) {
    checks.push(...tableChecks(catalog, stream, expected[stream.name], options.maxAgeDays));
  }

  const checksSql = [
    '-- Generated by scripts/generate-sink-sql.js. Do not edit.',
    'WITH results AS (',
    checks.join('\nUNION ALL\n'),
    ')',
    "SELECT coalesce(json_agg(json_build_object('table', table_name, 'check', check_name, 'expected', expected, 'actual', actual, 'ok', ok) ORDER BY table_name, check_name)::text, '[]')",
    'FROM results;',
    '',
  ].join('\n');

  const countsSql = [
    '-- Generated by scripts/generate-sink-sql.js. Do not edit.',
    "SELECT json_build_object(" +
      catalog.streams
        .map((stream) => {
          const table = stream.sink.table;
          return (
            `${quote(table)}, (SELECT json_build_object(` +
            `'rows', count(*), 'expected_rows', ${expected[stream.name].rows}, ` +
            `'distinct_members', count(DISTINCT member_id), ` +
            `'first_ingested_at', min(ingested_at), 'last_ingested_at', max(ingested_at), ` +
            `'oldest_member', min(created_at), 'newest_member', max(created_at)) FROM ${table})`
          );
        })
        .join(',\n       ') +
      ')::text;',
    '',
  ].join('\n');

  const waitSql = [
    '-- Generated by scripts/generate-sink-sql.js. Do not edit.',
    "SELECT CASE WHEN " +
      catalog.streams
        .map((stream) => `(SELECT count(*) FROM ${stream.sink.table}) >= ${expected[stream.name].rows}`)
        .join('\n     AND ') +
      "\n     THEN 'ready' ELSE 'waiting' END;",
    '',
  ].join('\n');

  const progressSql = [
    '-- Generated by scripts/generate-sink-sql.js. Do not edit.',
    catalog.streams
      .map(
        (stream) =>
          `SELECT ${quote(stream.sink.table)} AS table_name, count(*) AS rows, ${expected[stream.name].rows} AS expected FROM ${stream.sink.table}`,
      )
      .join('\nUNION ALL\n') + '\nORDER BY table_name;',
    '',
  ].join('\n');

  fs.mkdirSync(options.out, { recursive: true });
  fs.writeFileSync(path.join(options.out, 'checks.sql'), checksSql);
  fs.writeFileSync(path.join(options.out, 'counts.sql'), countsSql);
  fs.writeFileSync(path.join(options.out, 'wait.sql'), waitSql);
  fs.writeFileSync(path.join(options.out, 'progress.sql'), progressSql);
  fs.writeFileSync(path.join(options.out, 'expected.json'), JSON.stringify(expected, null, 2));

  process.stderr.write(
    `Generated ${checks.length} data quality checks for ${catalog.streams.length} tables in ${options.out}\n`,
  );
}

main();
