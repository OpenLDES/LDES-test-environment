#!/usr/bin/env bash
#
# Waits until the LDES server of a test environment serves every view of every event stream.
#
# The Helm release already waits for the pods to become ready, but two things can lag behind or
# fail silently afterwards:
#
#  - the OVHcloud load balancer and the DNS record behind the ingress hostname need a minute or
#    two;
#  - the chart configures the streams and the views with a post-install Job that appends
#    `|| echo "Warning: ..."` to every curl, so a rejected configuration document leaves the
#    stream or the view missing without failing the deployment.
#
# Checking every view is therefore the only way to know that the environment is really configured
# the way the catalogue describes it.
#
# Usage: wait-for-ldes-server.sh <timeout-seconds> <url> [url...]

set -euo pipefail

TIMEOUT="${1:?usage: wait-for-ldes-server.sh <timeout-seconds> <url> [url...]}"
shift

[ "$#" -gt 0 ] || { echo "No view URLs given." >&2; exit 1; }

deadline=$(( $(date +%s) + TIMEOUT ))

printf 'Waiting for %s view(s), timeout %ss\n' "$#" "$TIMEOUT"

remaining=("$@")

while :; do
    pending=()
    last_status=""

    for url in "${remaining[@]}"; do
        status=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "$url" || echo 000)

        if [ "$status" = "200" ]; then
            printf '  ready: %s\n' "$url"
        else
            pending+=("$url")
            last_status="$status"
        fi
    done

    if [ "${#pending[@]}" -eq 0 ]; then
        printf 'The LDES server serves every view.\n'
        exit 0
    fi

    if [ "$(date +%s)" -ge "$deadline" ]; then
        printf 'Timed out. %s view(s) are still not served (last status %s):\n' "${#pending[@]}" "$last_status" >&2
        printf '  %s\n' "${pending[@]}" >&2
        exit 1
    fi

    printf '  %s view(s) pending, retrying...\n' "${#pending[@]}"
    remaining=("${pending[@]}")
    sleep 10
done
