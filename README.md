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

The load test posts version objects to the LDES server, LDIO replicates the resulting event stream
through its `Ldio:LdesClient` input and flattens every member into a relational table with
`Ldio:LdioRdbOut`. The workflow then asserts that the members really landed in PostgreSQL, so the
test covers the whole chain rather than just the HTTP surface of the server.

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
loadtest/
  ldes-loadtest.js        k6 scenarios: constant rate ingest plus concurrent view reads
scripts/                  Helpers used by the workflows
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

| Variable                           | Example                                | Purpose                                                     |
|------------------------------------|----------------------------------------|-------------------------------------------------------------|
| `OVH_ENDPOINT`                     | `ovh-eu`                               | API endpoint matching your account                          |
| `OVH_REGION`                       | `GRA9`                                 | Region of the Kubernetes cluster                            |
| `OVH_DATABASE_REGION`              | `GRA`                                  | Region of the managed PostgreSQL cluster                    |
| `TF_STATE_BUCKET`                  | `ldes-test-environment-github-tfstate` | Bucket holding the Terraform state                          |
| `TF_STATE_REGION`                  | `gra`                                  | Region of that bucket                                       |
| `TF_STATE_ENDPOINT`                | `https://s3.gra.io.cloud.ovh.net`      | S3 endpoint of that bucket                                  |
| `LDES_BASE_DOMAIN`                 | *(unset)*                              | Optional. Domain for environment hostnames; see below       |
| `LDES_SERVER_IMAGE_TAG`            | `4.0.0`                                | Optional. LDES server image under test                      |
| `LDIO_IMAGE_TAG`                   | `3.1.1`                                | Optional. LDIO image under test                             |
| `LOADTEST_INGEST_RATE`             | `50`                                   | Optional. Ingest requests per second                        |
| `LOADTEST_DURATION`                | `3m`                                   | Optional. Duration of the load test                         |
| `LOADTEST_INGEST_VUS`              | `20`                                   | Optional. Pre-allocated ingest virtual users                |
| `LOADTEST_READ_RATE`               | `10`                                   | Optional. View reads per second                             |
| `LOADTEST_READ_VUS`                | `5`                                    | Optional. Pre-allocated read virtual users                  |
| `LOADTEST_MINIMUM_REPLICATED_ROWS` | `1`                                    | Optional. Rows LDIO must have written before the run passes |

### Hostnames

When `LDES_BASE_DOMAIN` is unset, every environment is reachable at
`pr-<number>.<load-balancer-ip>.nip.io`. [nip.io](https://nip.io) resolves that to the load balancer
address, so throwaway environments need no DNS management at all. Set `LDES_BASE_DOMAIN`
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
   the shared PostgreSQL cluster, the sink table, and the two Helm releases;
2. waits until the paged view is served through the ingress;
3. runs the k6 load test;
4. asserts through a Job inside the cluster that LDIO replicated the members into PostgreSQL;
5. posts a report as a pull request comment and to the job summary;
6. destroys the environment again.

Add the `keep-environment` label to a pull request to skip step 6 and inspect the environment by
hand. `pr-test-environment-cleanup.yml` destroys whatever is left when the pull request closes.

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

## Running the load test against an existing environment

```bash
cd loadtest
INGEST_URL=http://pr-12.203.0.113.nip.io/loadtest \
VIEW_URL=http://pr-12.203.0.113.nip.io/loadtest/by-page \
INGEST_RATE=50 INGEST_DURATION=2m \
k6 run ldes-loadtest.js
```

The script writes `loadtest-summary.json` and a Markdown table in `loadtest-summary.md`, and exits
non-zero when a threshold is breached.

## Data model

The generated payload, the sink table and the SPARQL query that maps one onto the other have to
agree. All three default to the same tiny observation shape:

| Turtle predicate           | SPARQL variable | Column       |
|----------------------------|-----------------|--------------|
| *(subject)*                | `?version_id`   | `version_id` |
| `dcterms:isVersionOf`      | `?member_id`    | `member_id`  |
| `dcterms:created`          | `?created_at`   | `created_at` |
| `<MEMBER_VOCABULARY>value` | `?value`        | `value`      |

Override `sink_table_ddl`, `sink_sparql_query` and `ldio_pipelines` on the `ldes-stack` module to
replicate a different dataset; the `member_vocabulary` output is passed to k6 so the payload keeps
matching the query.

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
- **Sink table.** `Ldio:LdioRdbOut` requires its target table to exist. The `ldes-stack` module
  therefore runs a bootstrap Job that applies the DDL before the LDIO release is installed.
- **Database firewall.** `database_ip_restrictions` defaults to `0.0.0.0/0` because the public
  egress addresses of MKS nodes are not known up front. Attach the cluster and the database to the
  same vRack, or narrow the list down, for anything that is not a test environment.
- **Cost.** The platform stack keeps a cluster and a database cluster running. Pull request
  environments themselves are cheap: a namespace and two databases.
