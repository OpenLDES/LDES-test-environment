#!/usr/bin/env bash
#
# Verifies that LDIO replicated the members produced by the load test into PostgreSQL.
#
# The sink database is only reachable from inside the cluster when the environment runs the
# throwaway in-cluster PostgreSQL, so the query is executed by a short lived Job in the
# environment namespace rather than from the runner.
#
# The connection URI is passed through a Secret, never through the Job command line, so it does
# not end up in the pod spec or in the workflow log.
#
# Usage:
#   SINK_DATABASE_URI=postgresql://... verify-replication.sh <namespace> <table> <minimum-rows> [timeout-seconds]

set -euo pipefail

NAMESPACE="${1:?usage: verify-replication.sh <namespace> <table> <minimum-rows> [timeout-seconds]}"
TABLE="${2:?missing table name}"
MINIMUM="${3:?missing minimum row count}"
TIMEOUT="${4:-600}"
IMAGE="${POSTGRES_IMAGE:-postgres:16-alpine}"

: "${SINK_DATABASE_URI:?SINK_DATABASE_URI must be set}"

JOB_NAME="ldes-verify-replication-$(date +%s)"
SECRET_NAME="${JOB_NAME}-connection"

cleanup() {
    kubectl -n "$NAMESPACE" delete job "$JOB_NAME" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    kubectl -n "$NAMESPACE" delete secret "$SECRET_NAME" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

kubectl -n "$NAMESPACE" create secret generic "$SECRET_NAME" \
    --from-literal=SINK_DATABASE_URI="$SINK_DATABASE_URI" >/dev/null

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
            - name: TABLE
              value: "${TABLE}"
            - name: MINIMUM
              value: "${MINIMUM}"
            - name: TIMEOUT
              value: "${TIMEOUT}"
          command:
            - /bin/sh
            - -c
            - |
              set -eu
              deadline=\$(( \$(date +%s) + TIMEOUT ))
              while :; do
                  count=\$(psql "\$SINK_DATABASE_URI" -tAc "SELECT count(*) FROM \$TABLE" 2>/dev/null || echo "")
                  if [ -n "\$count" ]; then
                      echo "replicated rows: \$count (expecting at least \$MINIMUM)"
                      if [ "\$count" -ge "\$MINIMUM" ]; then
                          echo "REPLICATED_ROWS=\$count"
                          exit 0
                      fi
                  else
                      echo "sink table not queryable yet"
                  fi
                  if [ "\$(date +%s)" -ge "\$deadline" ]; then
                      echo "timed out waiting for LDIO to replicate at least \$MINIMUM members" >&2
                      exit 1
                  fi
                  sleep 10
              done
YAML

echo "Waiting for LDIO to replicate at least ${MINIMUM} members into ${TABLE}..."

if kubectl -n "$NAMESPACE" wait --for=condition=complete "job/${JOB_NAME}" --timeout="$((TIMEOUT + 60))s" >/dev/null 2>&1; then
    kubectl -n "$NAMESPACE" logs "job/${JOB_NAME}" | tail -5
    echo "Replication verified."
    exit 0
fi

echo "Replication verification failed." >&2
kubectl -n "$NAMESPACE" logs "job/${JOB_NAME}" --tail=50 >&2 || true
exit 1
