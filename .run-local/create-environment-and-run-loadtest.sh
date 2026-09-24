#!/usr/bin/env bash
#
# Brings the test environment up from a workstation and runs the load test against it: the steps of
# .README.md sections 0 to 6, in order, without the copy-pasting.
#
# Usage:
#   .run-local/create-environment-and-run-loadtest.sh --destroy=<true|false> [--destroy-before=<true|false>]
#
# The whole run is unattended, with auto-approved applies, so both ends of the environment's life
# are arguments rather than questions. --destroy is required and has no default: leaving a cluster
# and a load balancer running by forgetting a flag is the expensive mistake, so the script would
# rather refuse to start than guess.
#
# Each of the three stacks is only applied when it is not already there, so without
# --destroy-before the script runs another load test against whatever is still up.
#
# A repeat run against a live environment shifts SEQUENCE_OFFSET past the members that environment
# already holds, because every member IRI is derived from its sequence number and republishing an
# IRI would silently turn new members into new versions of old ones.
#
# Credentials, the environment name and the load test parameters come from
# .run-local/configuration.sh; the OVHcloud project and the cluster shape come from
# terraform/stacks/platform/terraform.tfvars. Nothing is read from the environment of the calling
# shell.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

usage() {
    cat <<USAGE
Usage: .run-local/create-environment-and-run-loadtest.sh --destroy=<true|false> [--destroy-before=<true|false>]

  --destroy=true          Tear the environment down once the load test has finished.
  --destroy=false         Leave it running, so the report and the views can still be inspected.
                          Required: the environment costs money for as long as it runs, so the
                          script will not pick either answer for you.

  --destroy-before=true   Destroy a platform that is already running before building a new one,
                          for a clean run from an empty cluster.
  --destroy-before=false  Reuse whatever is already running and only create what is missing.
                          Default.

Examples:
  # One throwaway run: build it, load test it, tear it down.
  .run-local/create-environment-and-run-loadtest.sh --destroy=true

  # Another load test against the environment that is still up.
  .run-local/create-environment-and-run-loadtest.sh --destroy=false

  # Start from scratch and keep the result for inspection.
  .run-local/create-environment-and-run-loadtest.sh --destroy-before=true --destroy=false
USAGE
}

# Accepts only true and false. Anything else is a typo, and guessing what a typo meant is how a
# --destroy=ture run silently leaves a cluster behind. This validates in place rather than echoing
# a value back, so its exit reaches the script instead of dying in a command substitution.
require_boolean() {
    local name="$1" value="$2"

    case "${value}" in
        true|false) return 0 ;;
        *)
            echo "${name} must be true or false, not '${value}'." >&2
            exit 1
            ;;
    esac
}

destroy_after=''
destroy_before='false'

while [ "$#" -gt 0 ]; do
    case "$1" in
        --destroy=*)
            destroy_after="${1#*=}"
            require_boolean --destroy "${destroy_after}"
            ;;
        --destroy-before=*)
            destroy_before="${1#*=}"
            require_boolean --destroy-before "${destroy_before}"
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            echo >&2
            usage >&2
            exit 1
            ;;
    esac
    shift
done

if [ -z "${destroy_after}" ]; then
    echo "--destroy is required: say whether the environment should be torn down after the load test." >&2
    echo >&2
    usage >&2
    exit 1
fi

# shellcheck source=./configuration.sh
source "${SCRIPT_DIR}/configuration.sh"

: "${ENVIRONMENT_NAME:?ENVIRONMENT_NAME must be set in configuration.sh}"

# Every apply below passes -auto-approve, so an unanswerable "var.x: Enter a value" would hang the
# script rather than prompt anyone.
export TF_IN_AUTOMATION='true'
export TF_INPUT='0'

# How far beyond the last member of a live environment a repeat run starts. Round numbers keep the
# member IRIs of the two runs readable apart; override it in configuration.sh for a bigger gap.
SEQUENCE_MARGIN="${SEQUENCE_MARGIN:-100000}"

# .README.md, preamble: the tools the six steps need. Checking up front beats discovering halfway
# through that k6 is missing, twenty minutes and one cluster later.
missing=()
for tool in terraform kubectl helm k6 node jq curl; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done

if [ "${#missing[@]}" -gt 0 ]; then
    echo "Not on the PATH: ${missing[*]}" >&2
    exit 1
fi

PLAN_DIR="$(mktemp -d)"

# One directory per run, named after the moment the run started, so successive load tests against
# the same environment do not overwrite each other's evidence. Everything step 6 produces is
# written straight into it rather than copied in afterwards.
RUN_DIR="${REPO_ROOT}/reports/loadtest-$(date +%Y-%m-%d-%H-%M-%S)"
mkdir -p "${RUN_DIR}"

on_exit() {
    local status="$?"

    rm -rf "${PLAN_DIR}"

    # A run that failed before writing anything leaves an empty directory behind; rmdir removes it
    # only when it is in fact empty, so a partial run keeps whatever it did manage to write.
    rmdir "${RUN_DIR}" 2>/dev/null || true

    # A run that fails never reaches the teardown at the end, so under --destroy=true say what is
    # still standing. Destroying from here instead would throw away the very cluster that has to be
    # looked at to understand the failure. A failed report is not such a case: the teardown has run
    # by then, and teardown_done keeps this from crying wolf about it.
    if [ "${status}" -ne 0 ] && [ "${destroy_after}" = true ] && [ "${teardown_done}" = false ]; then
        echo >&2
        echo "The run failed before the teardown, so anything it created is still running." >&2
        echo "Inspect it, then run .run-local/destroy-environment.sh." >&2
    fi
}

teardown_done=false
trap on_exit EXIT

# Initialises one stack against its own state object in the remote state bucket. -reconfigure, never
# -migrate-state: migrating would copy the state of whatever backend this directory was last
# initialised against into the new key.
init_stack() {
    local stack="$1" state_key="$2"

    "${REPO_ROOT}/scripts/write-backend-config.sh" "terraform/stacks/${stack}" "${state_key}"
    terraform -chdir="terraform/stacks/${stack}" init -input=false -reconfigure -backend-config=backend.hcl
}

# Reads one output of a stack, or the empty string when the stack was never applied. `terraform
# output` exits 0 with only a warning on an empty state, so emptiness is the signal.
stack_output() {
    terraform -chdir="terraform/stacks/$1" output -raw "$2" 2>/dev/null || true
}

# Plans a stack and refuses to apply anything that would delete a resource. On a stack that only
# ever grows, a destroy in the plan means the backend key is wrong and this run is about to tear
# down the state of another stack.
apply_stack() {
    local stack="$1"
    local plan="${PLAN_DIR}/${stack}.tfplan"

    terraform -chdir="terraform/stacks/${stack}" plan -lock-timeout=5m -out="${plan}"

    local destroys
    destroys="$(terraform -chdir="terraform/stacks/${stack}" show -json "${plan}" |
        jq '[.resource_changes[]? | select(.change.actions | index("delete"))] | length')"

    # `[ "" -ne 0 ]` is a test error, not a false, and a test error inside `if` is not something
    # set -e catches. Without this the guard below would wave through a plan it could not read.
    if ! [[ "${destroys}" =~ ^[0-9]+$ ]]; then
        echo "Could not count the changes in the ${stack} plan." >&2
        exit 1
    fi

    if [ "${destroys}" -ne 0 ]; then
        echo >&2
        echo "The ${stack} plan wants to destroy ${destroys} resource(s), which it never should." >&2
        echo "Check that the stacks do not share a backend key before running this again." >&2
        exit 1
    fi

    terraform -chdir="terraform/stacks/${stack}" apply -lock-timeout=10m "${plan}"
}

# Highest air quality observation code in the sink, or 0 when the table is still empty.
#
# The member IRIs are AQ-<code> with code = sequence + 1, so the sink is the cheapest exact answer
# to "how far did the last run get": one query against one indexed column, instead of walking a
# paged view to its last fragment. The sink is only reachable from inside the cluster when the
# environment runs the throwaway in-cluster PostgreSQL, so the query runs as a short lived Job. The
# connection URI travels through a Secret, never through the Job command line, exactly as in
# scripts/verify-sink.sh.
latest_air_quality_code() {
    local namespace="$1"
    local job="ldes-latest-member-$(date +%s)"
    local secret="${job}-connection"
    local code

    kubectl -n "${namespace}" create secret generic "${secret}" \
        --from-literal=SINK_DATABASE_URI="${SINK_DATABASE_URI}" >/dev/null

    kubectl -n "${namespace}" apply -f - >/dev/null <<YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job}
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 300
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: probe
          image: ${POSTGRES_IMAGE:-postgres:16-alpine}
          envFrom:
            - secretRef:
                name: ${secret}
          command:
            - /bin/sh
            - -c
            - |
              psql "\$SINK_DATABASE_URI" -tAc "select coalesce(max(split_part(member_id, 'AQ-', 2)::bigint), 0) from air_quality_observations;"
YAML

    if kubectl -n "${namespace}" wait --for=condition=complete "job/${job}" --timeout=180s >/dev/null 2>&1; then
        code="$(kubectl -n "${namespace}" logs "job/${job}" 2>/dev/null | tr -d '[:space:]')"
    else
        code=''
        echo "The sink probe did not complete; its log follows." >&2
        kubectl -n "${namespace}" logs "job/${job}" >&2 2>/dev/null || true
    fi

    kubectl -n "${namespace}" delete job "${job}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    kubectl -n "${namespace}" delete secret "${secret}" --ignore-not-found --wait=false >/dev/null 2>&1 || true

    echo "${code}"
}

cd "${REPO_ROOT}"

# --------------------------------------------------------------------------------------------
# 1. Platform: cluster, node pool and managed PostgreSQL (~7 minutes when it has to be created)
# --------------------------------------------------------------------------------------------

echo "==> 1/6 Platform"
init_stack platform platform/terraform.tfstate

cluster_id="$(stack_output platform cluster_id)"
keep_platform=false

if [ -n "${cluster_id}" ]; then
    cluster_name="$(stack_output platform cluster_name)"
    echo "A platform is already running: cluster ${cluster_name:-unknown} (${cluster_id})."

    if [ "${destroy_before}" = true ]; then
        echo
        echo "==> --destroy-before=true, destroying the running platform first"
        "${SCRIPT_DIR}/destroy-environment.sh"

        # The destroy emptied the state this shell already read, so everything below has to start
        # from a freshly initialised stack.
        echo
        init_stack platform platform/terraform.tfstate
    else
        keep_platform=true
        echo "Keeping it; pass --destroy-before=true for a run from an empty cluster."
    fi
fi

if [ "${keep_platform}" = true ]; then
    echo "Platform is in place, not applying it."
else
    apply_stack platform
fi

# --------------------------------------------------------------------------------------------
# 2. Add-ons: ingress-nginx and its load balancer (~8 minutes when it has to be created)
# --------------------------------------------------------------------------------------------

echo
echo "==> 2/6 Add-ons"
init_stack addons addons/terraform.tfstate

# A read-only terraform_remote_state onto the platform outputs. Unrelated to this stack's own
# backend key, and it is correct for it to name platform/terraform.tfstate.
./scripts/write-remote-state-vars.sh terraform/stacks/addons platform

load_balancer_ip="$(stack_output addons load_balancer_ip)"

if [ -n "${load_balancer_ip}" ]; then
    echo "Add-ons are in place: ingress load balancer ${load_balancer_ip}."
else
    echo "No ingress controller yet, setting up the add-ons."
    apply_stack addons
fi

# --------------------------------------------------------------------------------------------
# 3. Environment: LDES server, LDIO and the sink (~4 minutes when it has to be created)
# --------------------------------------------------------------------------------------------

echo
echo "==> 3/6 Environment ${ENVIRONMENT_NAME}"
init_stack environment "environments/${ENVIRONMENT_NAME}/terraform.tfstate"
./scripts/write-remote-state-vars.sh terraform/stacks/environment platform addons
./scripts/write-environment-vars.sh terraform/stacks/environment

reuse_environment=false
ldes_server_url="$(stack_output environment ldes_server_url)"

if [ -n "${ldes_server_url}" ]; then
    # The state having outputs only means the environment was applied once. Asking one of its views
    # is what proves the server is actually serving right now. Step 5 checks all of them; one is
    # enough to decide whether this stack needs applying.
    first_view="$(terraform -chdir=terraform/stacks/environment output -json view_urls 2>/dev/null |
        jq -r '.[0] // empty' || true)"
    status="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
        "${first_view:-${ldes_server_url}}" || true)"

    if [ "${status}" = '200' ]; then
        reuse_environment=true
        echo "The LDES server is already running at ${ldes_server_url}."
    else
        echo "The environment is applied but its server answered ${status:-nothing}; re-applying."
    fi
fi

if [ "${reuse_environment}" != true ]; then
    apply_stack environment
    ldes_server_url="$(stack_output environment ldes_server_url)"
fi

export LDES_SERVER_URL="${ldes_server_url}"

# --------------------------------------------------------------------------------------------
# 4. Cluster credentials
# --------------------------------------------------------------------------------------------

echo
echo "==> 4/6 Cluster credentials"

# The kubeconfig is a cluster admin credential, so it must not be created world readable. umask
# applies to the shell that creates the file, hence the subshell around the redirection.
(umask 077; terraform -chdir=terraform/stacks/platform output -raw kubeconfig > kubeconfig)
export KUBECONFIG="${REPO_ROOT}/kubeconfig"

kubectl get nodes
kubectl -n "ldes-${ENVIRONMENT_NAME}" get pods

# --------------------------------------------------------------------------------------------
# 5. Wait for the server, then load test
# --------------------------------------------------------------------------------------------

echo
echo "==> 5/6 Load test"

if [ "${reuse_environment}" = true ]; then
    # The seeding run owns sequence numbers 0..seedCount-1 and the load test continues after them,
    # so a second run against these same members would republish their IRIs. Starting past
    # everything already in the environment keeps every generated IRI unique.
    #
    # SEQUENCE_OFFSET applies to every stream, and air quality observations are the largest of the
    # six, so the sequence they reached is the safe basis for all of them.
    if [ -n "${SEQUENCE_OFFSET:-}" ]; then
        echo "Using the SEQUENCE_OFFSET from configuration.sh: ${SEQUENCE_OFFSET}."
    else
        echo "Looking up the latest air quality observation."

        SINK_DATABASE_URI="$(terraform -chdir=terraform/stacks/environment output -raw sink_database_uri)"
        export SINK_DATABASE_URI

        namespace="$(terraform -chdir=terraform/stacks/environment output -raw namespace)"
        latest_code="$(latest_air_quality_code "${namespace}")"

        if ! [[ "${latest_code}" =~ ^[0-9]+$ ]]; then
            echo >&2
            echo "Could not read the latest air quality observation from the sink, so there is no" >&2
            echo "safe sequence to start after. Set SEQUENCE_OFFSET in configuration.sh to run" >&2
            echo "anyway, or destroy the environment for a clean run." >&2
            exit 1
        fi

        # The IRI carries the code, which is the sequence number plus one.
        if [ "${latest_code}" -gt 0 ]; then
            latest_sequence=$((latest_code - 1))
            echo "Latest air quality observation: AQ-$(printf '%06d' "${latest_code}"), sequence ${latest_sequence}."
        else
            latest_sequence=0
            echo "The sink holds no air quality observations yet."
        fi

        # Round up to a whole margin beyond the last member, so the new IRIs are unmistakably a
        # different run rather than one off the end of the previous one.
        SEQUENCE_OFFSET=$(((latest_sequence / SEQUENCE_MARGIN + 2) * SEQUENCE_MARGIN))
        echo "SEQUENCE_OFFSET=${SEQUENCE_OFFSET} (${SEQUENCE_MARGIN} or more past sequence ${latest_sequence})."
    fi

    export SEQUENCE_OFFSET
    echo "Reusing the seeded members of the running environment, so the seeding run is skipped."
else
    echo "==> Seeding (~190 members)"
    (cd loadtest && k6 run --no-usage-report seed.js)
fi

echo
echo "==> Waiting for every view to answer"

# The Helm release only waits for the pods. The ingress hostname needs another minute, and the
# chart configures streams and views in a post-install Job that swallows its own failures, so
# every view answering 200 is the only real readiness signal.
./scripts/wait-for-ldes-server.sh 900 \
    $(terraform -chdir=terraform/stacks/environment output -json view_urls | jq -r 'join(" ")')

echo
echo "==> Running the load test"
(cd loadtest && k6 run --no-usage-report ldes-loadtest.js)

# --------------------------------------------------------------------------------------------
# 6. Verify replication and build the report
# --------------------------------------------------------------------------------------------

echo
echo "==> 6/6 Sink verification and report"
echo "Writing this run to ${RUN_DIR#"${REPO_ROOT}/"}"

report_failed=false

# k6 overwrites these on every run, so the raw numbers behind the report only survive in the run
# directory. In reuse mode, where there is no report, they are the run's only record.
for artefact in seed-summary.json loadtest-summary.json loadtest-summary.md loadtest-metrics.json; do
    if [ -f "loadtest/${artefact}" ]; then
        cp "loadtest/${artefact}" "${RUN_DIR}/${artefact}"
    fi
done

if [ "${reuse_environment}" = true ]; then
    # The generated row counts are sized for one seeding run plus one load test, so they cannot
    # describe a database that already held the members of an earlier run. .README.md says to judge
    # a repeat run by the change in the server's own view counts instead.
    echo "Sink checks skipped: they expect a freshly seeded database, which this environment is not."
    echo "Compare ${RUN_DIR#"${REPO_ROOT}/"}/loadtest-summary.md against the previous run instead."
else
    node scripts/generate-sink-sql.js \
        --catalog catalog/streams.json \
        --seed loadtest/seed-summary.json \
        --loadtest loadtest/loadtest-metrics.json \
        --out "${RUN_DIR}/sql"

    SINK_DATABASE_URI="$(terraform -chdir=terraform/stacks/environment output -raw sink_database_uri)"
    export SINK_DATABASE_URI

    # The sink database is only reachable from inside the cluster, so the SQL runs as a short lived
    # Job in the environment namespace. That needs the KUBECONFIG written in step 4.
    ./scripts/verify-sink.sh \
        "$(terraform -chdir=terraform/stacks/environment output -raw namespace)" \
        "${RUN_DIR}/sql" "${RUN_DIR}" 900

    # build-report.js defaults every path to reports/, so each one has to be pointed at this run.
    # It exits 1 when the run misses its thresholds, which is a result and not a script error: the
    # report still has to be shown and the teardown still has to happen, so the verdict is carried
    # to the last line of the script instead of aborting here.
    if ! ENVIRONMENT_NAME="${ENVIRONMENT_NAME}" LDES_SERVER_URL="${LDES_SERVER_URL}" \
        node scripts/build-report.js \
            --replication "${RUN_DIR}/replication.json" \
            --counts "${RUN_DIR}/postgres-counts.json" \
            --checks "${RUN_DIR}/postgres-checks.json" \
            --out "${RUN_DIR}/report.md" \
            --json "${RUN_DIR}/report.json"
    then
        report_failed=true
    fi

    cat "${RUN_DIR}/report.md"
fi

echo
echo "Done. The load test ran against ${LDES_SERVER_URL}."
echo "Its report and artefacts are in ${RUN_DIR#"${REPO_ROOT}/"}"

# --------------------------------------------------------------------------------------------
# 7. Tear down, if that is what was asked for
# --------------------------------------------------------------------------------------------

if [ "${destroy_after}" = true ]; then
    echo
    echo "==> --destroy=true, tearing the environment down"
    "${SCRIPT_DIR}/destroy-environment.sh"
    teardown_done=true
else
    echo "It stays up until you run .run-local/destroy-environment.sh."
fi

# The verdict of the report is the verdict of the run, but only after the teardown above has had
# its turn: a load test that misses its thresholds must still not leave a cluster running.
if [ "${report_failed}" = true ]; then
    echo
    echo "The report marks this run as failed; see ${RUN_DIR#"${REPO_ROOT}/"}/report.md." >&2
    exit 1
fi
