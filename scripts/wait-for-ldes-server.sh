#!/usr/bin/env bash
#
# Waits until the LDES server of a test environment serves its event stream.
#
# The Helm release already waits for the pods to become ready, but the OVHcloud load balancer and
# the DNS record behind the ingress hostname can lag behind by a minute or two.
#
# Usage: wait-for-ldes-server.sh <url> [timeout-seconds]

set -euo pipefail

URL="${1:?usage: wait-for-ldes-server.sh <url> [timeout-seconds]}"
TIMEOUT="${2:-600}"

deadline=$(( $(date +%s) + TIMEOUT ))

printf 'Waiting for %s (timeout %ss)\n' "$URL" "$TIMEOUT"

while :; do
    status=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$URL" || echo 000)

    if [ "$status" = "200" ]; then
        printf 'LDES server is serving %s\n' "$URL"
        exit 0
    fi

    if [ "$(date +%s)" -ge "$deadline" ]; then
        printf 'Timed out waiting for %s, last status %s\n' "$URL" "$status" >&2
        exit 1
    fi

    printf '  status %s, retrying...\n' "$status"
    sleep 10
done
