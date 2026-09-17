#!/usr/bin/env bash
#
# Waits until LDIO has replicated every member into PostgreSQL, then runs the generated data
# quality checks and writes their results next to the load test artefacts.
#
# The sink database is only reachable from inside the cluster when the environment runs the
# throwaway in-cluster PostgreSQL, so everything is executed by a short lived Job in the
# environment namespace rather than from the runner. The connection URI travels through a Secret,
# never through the Job command line, so it does not end up in the pod spec or in the workflow log.
#
# Usage:
#   SINK_DATABASE_URI=postgresql://... scripts/verify-sink.sh <namespace> <sql-dir> <output-dir> [timeout-seconds]

set -euo pipefail

NAMESPACE="${1:?usage: verify-sink.sh <namespace> <sql-dir> <output-dir> [timeout-seconds]}"
SQL_DIR="${2:?missing directory with the generated SQL}"
OUTPUT_DIR="${3:?missing output directory}"
TIMEOUT="${4:-900}"
IMAGE="${POSTGRES_IMAGE:-postgres:16-alpine}"

: "${SINK_DATABASE_URI:?SINK_DATABASE_URI must be set}"

for file in wait.sql progress.sql counts.sql checks.sql; do
    [ -f "${SQL_DIR}/${file}" ] || { echo "Missing ${SQL_DIR}/${file}; run scripts/generate-sink-sql.js first." >&2; exit 1; }
done

mkdir -p "$OUTPUT_DIR"

JOB_NAME="ldes-verify-sink-$(date +%s)"
SECRET_NAME="${JOB_NAME}-connection"
CONFIG_NAME="${JOB_NAME}-sql"

cleanup() {
    kubectl -n "$NAMESPACE" delete job "$JOB_NAME" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    kubectl -n "$NAMESPACE" delete secret "$SECRET_NAME" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    kubectl -n "$NAMESPACE" delete configmap "$CONFIG_NAME" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

kubectl -n "$NAMESPACE" create secret generic "$SECRET_NAME" \
    --from-literal=SINK_DATABASE_URI="$SINK_DATABASE_URI" >/dev/null

kubectl -n "$NAMESPACE" create configmap "$CONFIG_NAME" \
    --from-file="${SQL_DIR}/wait.sql" \
    --from-file="${SQL_DIR}/progress.sql" \
    --from-file="${SQL_DIR}/counts.sql" \
    --from-file="${SQL_DIR}/checks.sql" >/dev/null

kubectl -n "$NAMESPACE" apply -f - >/dev/null <<YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB_NAME}
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: verify
          image: ${IMAGE}
          envFrom:
            - secretRef:
                name: ${SECRET_NAME}
          env:
            - name: TIMEOUT
              value: "${TIMEOUT}"
          volumeMounts:
            - name: sql
              mountPath: /sql
              readOnly: true
          command:
            - /bin/sh
            - -c
            - |
              set -eu
              deadline=\$(( \$(date +%s) + TIMEOUT ))
              started=\$(date +%s)
              status=timeout

              while :; do
                  state=\$(psql "\$SINK_DATABASE_URI" -tAf /sql/wait.sql 2>/dev/null | tr -d '[:space:]' || echo "")

                  if [ "\$state" = "ready" ]; then
                      status=ready
                      break
                  fi

                  if [ "\$(date +%s)" -ge "\$deadline" ]; then
                      echo "Timed out waiting for LDIO to replicate every member." >&2
                      break
                  fi

                  echo "--- waiting for replication (\$(( \$(date +%s) - started ))s) ---"
                  psql "\$SINK_DATABASE_URI" -tAf /sql/progress.sql 2>/dev/null || echo "sink not queryable yet"
                  sleep 10
              done

              waited=\$(( \$(date +%s) - started ))
              echo "---REPLICATION---"
              echo "{\"status\":\"\$status\",\"waitedSeconds\":\$waited}"
              echo "---COUNTS---"
              psql "\$SINK_DATABASE_URI" -tAf /sql/counts.sql
              echo "---CHECKS---"
              psql "\$SINK_DATABASE_URI" -tAf /sql/checks.sql
              echo "---END---"
      volumes:
        - name: sql
          configMap:
            name: ${CONFIG_NAME}
YAML

echo "Waiting for LDIO to replicate every member into PostgreSQL (timeout ${TIMEOUT}s)..."

# `kubectl wait --for=condition=complete` does not return early on a failed Job, so a container
# that dies on startup would otherwise burn the whole timeout before anything is reported.
job_deadline=$(( $(date +%s) + TIMEOUT + 180 ))

while :; do
    complete=$(kubectl -n "$NAMESPACE" get "job/${JOB_NAME}" \
        -o 'jsonpath={.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || true)
    failed=$(kubectl -n "$NAMESPACE" get "job/${JOB_NAME}" \
        -o 'jsonpath={.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || true)

    if [ "$complete" = "True" ]; then
        break
    fi

    if [ "$failed" = "True" ]; then
        echo "The verification job failed." >&2
        break
    fi

    if [ "$(date +%s)" -ge "$job_deadline" ]; then
        echo "Timed out waiting for the verification job to finish." >&2
        break
    fi

    sleep 10
done

logs="$(kubectl -n "$NAMESPACE" logs "job/${JOB_NAME}" 2>&1 || true)"

if [ -z "$logs" ]; then
    echo "The verification job produced no output." >&2
    kubectl -n "$NAMESPACE" describe "job/${JOB_NAME}" >&2 || true
    exit 1
fi

section() {
    printf '%s\n' "$logs" | awk -v start="---$1---" -v end="---$2---" '
        $0 == start { capture = 1; next }
        $0 == end   { capture = 0 }
        capture     { print }
    ' | tr -d '\r' | sed '/^[[:space:]]*$/d'
}

# Everything the container printed while it was waiting, so the job log shows the catch-up.
printf '%s\n' "$logs" | awk '$0 == "---REPLICATION---" { exit } { print }'

section REPLICATION COUNTS > "${OUTPUT_DIR}/replication.json"
section COUNTS CHECKS > "${OUTPUT_DIR}/postgres-counts.json"
section CHECKS END > "${OUTPUT_DIR}/postgres-checks.json"

for file in replication.json postgres-counts.json postgres-checks.json; do
    if [ ! -s "${OUTPUT_DIR}/${file}" ]; then
        echo "The verification job did not produce ${file}." >&2
        printf '%s\n' "$logs" | tail -40 >&2
        exit 1
    fi
done

echo "Wrote ${OUTPUT_DIR}/replication.json, ${OUTPUT_DIR}/postgres-counts.json and ${OUTPUT_DIR}/postgres-checks.json"
