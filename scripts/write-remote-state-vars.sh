#!/usr/bin/env bash
#
# Writes a *.auto.tfvars.json file that tells a stack how to read the remote state of the stacks
# it depends on. Only backend addressing is written; the S3 credentials stay in the environment.
#
# Usage: write-remote-state-vars.sh <stack-directory> <dependency> [dependency...]
#
# A dependency is the name of another stack, which maps onto the variable "<name>_remote_state"
# and the state key "<name>/terraform.tfstate".
#
# Required environment: TF_STATE_BUCKET, TF_STATE_REGION, TF_STATE_ENDPOINT.

set -euo pipefail

STACK_DIR="${1:?usage: write-remote-state-vars.sh <stack-directory> <dependency> [dependency...]}"
shift

: "${TF_STATE_BUCKET:?TF_STATE_BUCKET must be set}"
: "${TF_STATE_REGION:?TF_STATE_REGION must be set}"
: "${TF_STATE_ENDPOINT:?TF_STATE_ENDPOINT must be set}"

if [ "$#" -eq 0 ]; then
    echo "At least one dependency stack must be given" >&2
    exit 1
fi

target="${STACK_DIR%/}/remote-state.auto.tfvars.json"

{
    echo '{'

    first=true
    for dependency in "$@"; do
        if [ "$first" = true ]; then
            first=false
        else
            echo ','
        fi

        cat <<JSON
  "${dependency}_remote_state": {
    "bucket": "${TF_STATE_BUCKET}",
    "key": "${dependency}/terraform.tfstate",
    "region": "${TF_STATE_REGION}",
    "endpoints": { "s3": "${TF_STATE_ENDPOINT}" },
    "use_path_style": true,
    "skip_credentials_validation": true,
    "skip_region_validation": true,
    "skip_requesting_account_id": true,
    "skip_metadata_api_check": true,
    "skip_s3_checksum": true
  }
JSON
    done

    echo '}'
} > "$target"

echo "Wrote ${target}"
