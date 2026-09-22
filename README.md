# LDES test environment

Terraform and GitHub Actions configuration that builds a disposable test environment for an
[LDES server](https://github.com/OpenLDES/LDESServer) together with an
[LDI Orchestrator (LDIO)](https://github.com/OpenLDES/Linked-Data-Interactions) that consumes the
data from that LDES server and writes it into a PostgreSQL database.

Everything runs on OVHcloud: a Managed Kubernetes Service (MKS) cluster, a managed PostgreSQL
cluster and the [OpenLDES Helm charts](https://github.com/OpenLDES/helm-charts). Every pull request
gets its own environment, which is load tested and then torn down again.

## How it works

```
                              ┌──────────────────────── OVHcloud Public Cloud ────────────────────────┐
                              │                                                                       │
  k6 load test  ──ingest──▶   │  ingress-nginx ──▶ LDES server ──┐                                    │
  (GitHub runner)             │        ▲                         │ jdbc                               │
        │                     │        │ replicate               ▼                                    │
        └────read view────────┼────────┴──── LDIO ──jdbc──▶ managed PostgreSQL                        │
                              │                                  (ldes_server_pr_N, ldio_pr_N)        │
                              └───────────────────────────────────────────────────────────────────────┘
```

The environment publishes **six event streams** of environmental monitoring data with **fifteen
views** between them, seeded with a realistic basis of sensors, monitoring stations and water
bodies. A k6 load test ingests members into every stream and then queries every view, LDIO
replicates each stream into its own PostgreSQL table, and the run is only green when the row
counts, the referential integrity between the streams and the configured time metrics all hold.

## Repository layout

```
terraform/
  modules/
    kubernetes/           OVHcloud Managed Kubernetes cluster and its node pools
    postgresql/           OVHcloud managed PostgreSQL cluster
    postgresql-database/  A logical database on that cluster, with connection details
    ingress-nginx/        Ingress controller and its OVHcloud load balancer
    ldes-stack/           LDES server + LDIO + sink schema, from the OpenLDES Helm charts
  stacks/
    platform/             Long lived: cluster and database            (OVHcloud provider only)
    addons/               Long lived: ingress controller              (Kubernetes/Helm)
    environment/          Per pull request: namespace, databases, LDES server and LDIO
catalog/
  streams.json            Single source of truth: streams, views, sink tables, quality checks
loadtest/
  seed.js                 Ingests the realistic basis the streams reference each other through
  ldes-loadtest.js        Per stream ingest scenarios, followed by multi user view queries
  lib/                    Reference data and the member generators for the six data models
scripts/
  generate-sink-sql.js    Renders the row count and data quality SQL from the catalogue
  verify-sink.sh          Waits for LDIO, then runs that SQL inside the cluster
  build-report.js         Builds the report and fails on quality issues or breached metrics
.github/
  actions/terraform-setup Composite action that installs Terraform and wires up remote state
  workflows/              Terraform checks, platform lifecycle, pull request environments
docs/backend.hcl.example  Remote state configuration for OVHcloud Object Storage
```

### Why three stacks

The Kubernetes and Helm providers have to be configured with the credentials of a cluster. If the
cluster were created in the same run, those credentials would be unknown at plan time, which
Terraform cannot handle reliably. Splitting the configuration keeps every provider configured from
values that already exist:

| Stack         | Creates                                        | Lifecycle                              |
|---------------|------------------------------------------------|----------------------------------------|
| `platform`    | MKS cluster, node pools, managed PostgreSQL    | Applied from `main`, rarely changes    |
| `addons`      | ingress-nginx and its load balancer            | Applied from `main`, after `platform`  |
| `environment` | namespace, per-PR databases, LDES server, LDIO | Created and destroyed per pull request |

`addons` and `environment` read the outputs they need through `terraform_remote_state`.

## Prerequisites

1. An OVHcloud account with a Public Cloud project.
2. API credentials for that account. Either the classic triplet from the
   [token creation page](https://api.ovh.com/createToken/?GET=/*&POST=/*&PUT=/*&DELETE=/*) or an
   OAuth2 service account. See the
   [OVHcloud Terraform guide](https://docs.ovhcloud.com/en/guides/manage-and-operate/terraform/at-ovhcloud).
3. An Object Storage (S3 compatible) bucket plus an S3 user for the Terraform state.

## GitHub configuration

No credential or environment specific value lives in this repository. Everything is read from GitHub
secrets and variables.

### Secrets

| Secret                      | Purpose                            |
|-----------------------------|------------------------------------|
| `OVH_APPLICATION_KEY`       | OVHcloud API application key       |
| `OVH_APPLICATION_SECRET`    | OVHcloud API application secret    |
| `OVH_CONSUMER_KEY`          | OVHcloud API consumer key          |
| `OVH_CLOUD_PROJECT_SERVICE` | ID of the Public Cloud project     |
| `TF_STATE_ACCESS_KEY`       | S3 access key for the state bucket |
| `TF_STATE_SECRET_KEY`       | S3 secret key for the state bucket |

To use an OAuth2 service account instead, replace the three `OVH_APPLICATION_*` / `OVH_CONSUMER_KEY`
secrets with `OVH_CLIENT_ID` and `OVH_CLIENT_SECRET` and forward those in the workflow `env`
blocks; the provider picks up either pair from the environment.

### Variables

| Variable                               | Example                                | Purpose                                                            |
|----------------------------------------|----------------------------------------|--------------------------------------------------------------------|
| `OVH_ENDPOINT`                         | `ovh-eu`                               | API endpoint matching your account                                 |
| `OVH_REGION`                           | `GRA9`                                 | Region of the Kubernetes cluster                                   |
| `OVH_DATABASE_REGION`                  | `GRA`                                  | Region of the managed PostgreSQL cluster                           |
| `TF_STATE_BUCKET`                      | `ldes-test-environment-github-tfstate` | Bucket holding the Terraform state                                 |
| `TF_STATE_REGION`                      | `gra`                                  | Region of that bucket                                              |
| `TF_STATE_ENDPOINT`                    | `https://s3.gra.io.cloud.ovh.net`      | S3 endpoint of that bucket                                         |
| `LDES_BASE_DOMAIN`                     | *(unset)*                              | Optional. Domain for environment hostnames; see below              |
| `LDES_SERVER_IMAGE`                    | `openldes/ldes-server`                 | Optional. LDES server image repository under test                  |
| `LDES_SERVER_IMAGE_TAG`                | `4.1.2`                                | Optional. LDES server image tag under test                         |
| `LDIO_IMAGE`                           | `openldes/ldi-orchestrator`            | Optional. LDIO image repository under test                         |
| `LDIO_IMAGE_TAG`                       | `3.1.1`                                | Optional. LDIO image tag under test                                |
| `LOADTEST_MEMBER_SCALE`                | `1`                                    | Optional. Multiplies every member count; use `0.1` for a quick run |
| `LOADTEST_INGEST_VUS`                  | `1`                                    | Optional. Publishing users per stream                              |
| `LOADTEST_QUERY_VUS`                   | `10`                                   | Optional. Users querying the views                                 |
| `LOADTEST_QUERY_RATE`                  | `20`                                   | Optional. View requests per second                                 |
| `LOADTEST_QUERY_DURATION_SECONDS`      | `120`                                  | Optional. Length of the query phase                                |
| `LOADTEST_SETTLE_SECONDS`              | `45`                                   | Optional. Pause between ingesting and querying                     |
| `LOADTEST_REPLICATION_TIMEOUT_SECONDS` | `900`                                  | Optional. How long LDIO may take to catch up                       |
| `REPORT_MAX_INGEST_P95_MS`             | `2000`                                 | Optional. Fails the run when the ingest p95 is higher              |
| `REPORT_MAX_QUERY_P95_MS`              | `3000`                                 | Optional. Fails the run when the query p95 is higher               |
| `REPORT_MAX_VIEW_P95_MS`               | `5000`                                 | Optional. Fails the run when any single view is slower             |
| `REPORT_MAX_REPLICATION_SECONDS`       | `600`                                  | Optional. Fails the run when LDIO lags behind for longer           |
| `REPORT_MIN_INGEST_COMPLETION`         | `0.95`                                 | Optional. Fraction of the target members that must be ingested     |

Per stream volumes and rates default to the values in `catalog/streams.json` and are overridden
with `LT_<STREAM>_MEMBERS` and `LT_<STREAM>_RATE`, for example
`LT_AIR_QUALITY_OBSERVATIONS_MEMBERS` and `LT_AIR_QUALITY_OBSERVATIONS_RATE`.

### Hostnames

When `LDES_BASE_DOMAIN` is unset, every environment is reachable at
`pr-<number>.<load-balancer-ip-with-dashes>.nip.io`, for example
`pr-12.203-0-113-45.nip.io`. [nip.io](https://nip.io) resolves that to the load balancer
address, so throwaway environments need no DNS management at all. The dashed form is required:
nip.io resolves a name to the first dotted quad it finds, so `pr-12.203.0.113.45.nip.io` would
resolve to `12.203.0.113` instead of the load balancer. Set `LDES_BASE_DOMAIN`
to a wildcard domain you control (`*.ldes.example.org`) to use real hostnames instead.

## Bootstrapping

1. Create the state bucket and the S3 user, then set the secrets and variables above.
2. Run the **Platform** workflow manually with `apply`, or merge a change under
   `terraform/stacks/platform/`, `terraform/stacks/addons/` or `terraform/modules/`.

Creating an MKS cluster and a managed PostgreSQL cluster takes roughly 10 to 20 minutes. The
OVHcloud load balancer behind the ingress controller is provisioned asynchronously; if the
`load_balancer_is_provisioned` check reports that no address has been recorded yet, re-run the
workflow once the load balancer is up so the address lands in the state.

## Pull request environments

`.github/workflows/pr-test-environment.yml` runs on every pull request and:

1. applies the `environment` stack, which creates the namespace `ldes-pr-<number>`, two databases on
   the shared PostgreSQL cluster, the six sink tables, the six event streams with their views and
   the six LDIO pipelines;
2. waits until *every* view is served through the ingress;
3. ingests the realistic basis with `loadtest/seed.js`;
4. runs the k6 load test: per stream ingestion followed by a multi user query phase;
5. waits until LDIO has replicated every member into PostgreSQL and runs the generated data
   quality checks inside the cluster;
6. builds a report, validates it, and fails the run on a data quality issue or a breached time
   metric;
7. posts the report as a pull request comment and to the job summary;
8. destroys the environment again.

Add the `keep-environment` label to a pull request to skip step 8 and inspect the environment by
hand. `pr-test-environment-cleanup.yml` destroys whatever is left when the pull request closes.

The same workflow can be run manually against any branch. It then deploys a standalone environment
named after the `environment-name` input (`manual` by default, anything that is a DNS label of at
most 32 characters) rather than `pr-<number>`, and skips step 7 because there is no pull request to
comment on. Tick `keep-environment` to skip step 8. A manual environment is never closed, so the
cleanup workflow never picks it up: run the workflow again with the same name and without
`keep-environment` to destroy it.

## Running a stack locally

```bash
cd terraform/stacks/platform

cp ../../../docs/backend.hcl.example backend.hcl   # then fill it in
cp terraform.tfvars.example terraform.tfvars       # then fill it in

export OVH_ENDPOINT=ovh-eu
export OVH_APPLICATION_KEY=... OVH_APPLICATION_SECRET=... OVH_CONSUMER_KEY=...
export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=...

terraform init -backend-config=backend.hcl
terraform apply
```

For `addons` and `environment`, generate the remote state wiring first:

```bash
export TF_STATE_BUCKET=... TF_STATE_REGION=... TF_STATE_ENDPOINT=...
./scripts/write-remote-state-vars.sh terraform/stacks/environment platform addons
```

## Streams, views and the data model

Everything is derived from **`catalog/streams.json`**. That one document drives the LDES server
configuration, the LDIO pipelines, the sink schema, the payload the load test generates and the SQL
that validates the result, so those five can never drift apart.

### The six streams

| Stream                     | Model   | Geo | References                                                                         | Views                                         |
|----------------------------|---------|-----|------------------------------------------------------------------------------------|-----------------------------------------------|
| `water-sensors`            | simple  | yes | –                                                                                  | `by-page`, `by-location`                      |
| `air-quality-observations` | simple  | yes | –                                                                                  | `by-page`, `by-location`, `by-hour`, `by-day` |
| `water-level-measurements` | simple  | no  | –                                                                                  | `by-page`                                     |
| `monitoring-stations`      | complex | yes | `water-sensors`, `water-bodies`                                                    | `by-page`, `by-location`                      |
| `water-bodies`             | complex | yes | `monitoring-stations`, `water-level-measurements`                                  | `by-page`, `by-location`                      |
| `pollution-incidents`      | complex | yes | `water-bodies`, `monitoring-stations`, `water-sensors`, `air-quality-observations` | `by-page`, `by-location`, `by-hour`, `by-day` |

The complex models use SOSA/SSN, GeoSPARQL, `locn:` and `org:` and nest blank nodes for addresses,
operators, quality assessments, catchments, severity assessments and substances. They reference both
the other complex streams and the simple streams, which is what makes the referential integrity
checks on the PostgreSQL side meaningful.

Every stream with a geometry also has a `by-location` view (`tree:GeospatialFragmentation` on
`geosparql:asWKT`). Two streams carry two time based views with a
different granularity (`tree:HierarchicalTimeBasedFragmentation` on `dcterms:created`, `hour` and
`day`), and every stream has a `by-page` view, which is the one LDIO replicates from.

### The realistic basis

`loadtest/seed.js` publishes a fixed, deterministic set of reference members — water bodies of the
Flemish Water Framework Directive network, the monitoring stations along them, the sensors those
stations host — before the load test starts. The load test only ever references members from that
basis, so every foreign key in PostgreSQL resolves. Streams marked `versioned` in the catalogue
republish the seeded members as new versions, which is why their distinct member count stays equal
to the size of the reference pool while their row count grows.

### From Turtle to a table row

Each sink column declares the RDF property path it is filled from, and `Ldio:LdioRdbOut` maps the
SPARQL variable names straight onto column names:

| Catalogue type | Turtle literal                  | SPARQL projection | Column             |
|----------------|---------------------------------|-------------------|--------------------|
| `iri`          | `<...>`                         | `STR(?x)`         | `text`             |
| `string`       | `"..."`                         | `STR(?x)`         | `text`             |
| `date`         | `"2021-04-08"`                  | `STR(?x)`         | `text`             |
| `wktPoint`     | `"POINT (...)"^^geo:wktLiteral` | `STR(?x)`         | `text`             |
| `dateTime`     | `"..."^^xsd:dateTime`           | raw               | `timestamptz`      |
| `double`       | `"1.25"^^xsd:double`            | raw               | `double precision` |
| `integer`      | `"3"^^xsd:int`                  | raw               | `integer`          |

The projection column is not cosmetic. LDIO hands whatever Jena's `Literal.getValue()` returns
straight to `PreparedStatement.setObject`, so `xsd:integer` (a `BigInteger`), `xsd:date` (an
`XSDDateTime`) and `geosparql:wktLiteral` (an unregistered `TypedValue`) cannot be bound at all.
Forcing those through `STR()` is what keeps the WKT geometry — which the geospatial fragmentation
needs as a typed literal — writable to a `text` column.

## Running the load test against an existing environment

```bash
cd loadtest

# The realistic basis, once.
LDES_SERVER_URL=http://pr-12.203-0-113-45.nip.io \ 
k6 run seed.js

# The load test itself.
LDES_SERVER_URL=http://pr-12.203-0-113-45.nip.io \
INGEST_VUS=1 QUERY_VUS=10 QUERY_DURATION_SECONDS=120 \
LT_AIR_QUALITY_OBSERVATIONS_MEMBERS=10000 LT_AIR_QUALITY_OBSERVATIONS_RATE=40 \
k6 run ldes-loadtest.js
```

`MEMBER_SCALE=0.05` shrinks every stream proportionally for a quick smoke run. The load test writes
`seed-summary.json`, `loadtest-summary.json`, `loadtest-metrics.json` and `loadtest-summary.md`, and
exits non-zero when a k6 threshold is breached.

Every member IRI is derived from a sequence number that starts right after the seeding run, so a
second load test against an environment that still holds the members of an earlier one would
republish the same IRIs. `SEQUENCE_OFFSET=20000` shifts the whole range past what the earlier run
used, which makes comparing two runs possible without re-creating the environment. The sink
validation below still expects a freshly seeded database, so judge a repeat run by the change in
the server's own view counts rather than by the generated report.

## Validating the PostgreSQL sink

```bash
node scripts/generate-sink-sql.js \
    --seed loadtest/seed-summary.json \
    --loadtest loadtest/loadtest-metrics.json \
    --out reports/sql

SINK_DATABASE_URI="$(terraform -chdir=terraform/stacks/environment output -raw sink_database_uri)" \
./scripts/verify-sink.sh ldes-pr-12 reports/sql reports 900

node scripts/build-report.js --out report.md --json reports/report.json
```

`generate-sink-sql.js` turns the catalogue and the two k6 summaries into three SQL documents: one
that reports whether every member has arrived, one that returns the row counts and replication
timestamps, and one that runs roughly 180 data quality checks — row counts, distinct member counts,
version identity, referential integrity between the streams, `NOT NULL`, identifier patterns,
enumerations, numeric ranges, ISO dates, WKT syntax and a geographic bounding box.

`verify-sink.sh` runs all of that from a Job inside the namespace, because the sink database is not
reachable from the runner when the environment uses the throwaway in-cluster PostgreSQL. The
connection URI travels through a Secret, never through the pod spec.

`build-report.js` combines the load test metrics, the row counts and the checks into one report. It
**validates the report itself** — every stream must have been seeded, ingested, counted and checked,
every view must have been queried, and the counts reported by k6 and by PostgreSQL must agree — and
exits non-zero on a data quality issue, on incomplete replication, or on a breached time metric.

## Notes and limitations

- **Single instance components.** Neither the LDES server nor LDIO supports horizontal scaling yet,
  so both are pinned to one replica and autoscaling is off. The load test therefore measures a
  single instance.
- **Secrets in ConfigMaps.** The `openldes-ldio` chart renders its Spring datasource, including the
  password, into a ConfigMap, and offers no way to inject environment variables. For the LDES server
  this is avoided by passing `SPRING_DATASOURCE_PASSWORD` through the chart's `env` map. Both charts
  would need an `existingSecret` option to do better.
- **Database privileges.** The `postgresql-database` module connects the applications as the cluster
  superuser by default. A freshly created OVHcloud (Aiven) PostgreSQL user receives no privileges on
  the `public` schema of an existing database, so the LDES server would not be able to create its
  own tables. Isolation between environments comes from the separate databases.
- **Sink tables.** `Ldio:LdioRdbOut` requires its target table to exist. The `ldes-stack` module
  therefore runs a bootstrap Job that applies the generated DDL before the LDIO release is
  installed.
- **In-memory LDES client state.** The six LDIO pipelines run with `state: memory`. The SQL backed
  state of the LDES client stores its work queue and its exactly-once filter in fixed table names
  (`member`, `member_id`, `member_hashed`, `treenode`) without a pipeline discriminator, and offers
  no schema or table prefix setting, so pipelines sharing a database would consume each other's
  members. `ldes_client_state` therefore only accepts a SQL state when the catalogue holds a single
  stream; anything else needs one database per pipeline.
- **One member per request.** The streams are configured with `ldes:createVersions false`, because
  the load test generates the version IRIs itself and needs them to be unique and predictable. The
  server only accepts several members in one request when it creates the versions, so ingestion
  posts one member at a time and volume comes from the rate and the number of publishing users.
- **Silent configuration failures.** The `openldes-server` chart configures streams and views from a
  post-install Job whose every `curl` ends in `|| echo "Warning: ..."`, so a rejected configuration
  document does not fail the deployment. `wait-for-ldes-server.sh` therefore polls every view of
  every stream instead of a single URL.
- **Geospatial fragmentation needs `SIS_DATA`.** The by-location views are backed by Apache SIS,
  which needs a writable data directory and lengthens the start-up time of the server.
- **Database firewall.** `database_ip_restrictions` defaults to `0.0.0.0/0` because the public
  egress addresses of MKS nodes are not known up front. Attach the cluster and the database to the
  same vRack, or narrow the list down, for anything that is not a test environment.
- **Cost.** The platform stack keeps a cluster and a database cluster running. Pull request
  environments themselves are cheap: a namespace and two databases.
