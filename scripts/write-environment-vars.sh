#!/usr/bin/env bash
#
# Writes environment.auto.tfvars.json for the environment stack.
#
# GitHub repository variables are empty strings when they are not configured, which Terraform
# would happily accept as a real value. Only variables that actually carry a value are written,
# so the Terraform defaults stay in effect for the rest. Writing them to a file rather than
# exporting TF_VAR_* also means a later `terraform destroy` in the same checkout sees exactly the
# same inputs as the apply that created the environment.
#
# Usage: write-environment-vars.sh <stack-directory>
#
# Recognised environment variables:
#   ENVIRONMENT_NAME              (required) name of the environment, e.g. pr-123
#   LDES_BASE_DOMAIN              optional domain for the environment hostname
#   LDES_SERVER_IMAGE             optional LDES server repository and image
#   LDES_SERVER_IMAGE_TAG         optional LDES server image tag
#   LDIO_IMAGE                    optional LDIO repository and image
#   LDIO_IMAGE_TAG                optional LDIO image tag
#   PULL_REQUEST_NUMBER           optional, recorded as a label
#   COMMIT_SHA                    optional, recorded as a label

set -euo pipefail

STACK_DIR="${1:?usage: write-environment-vars.sh <stack-directory>}"
: "${ENVIRONMENT_NAME:?ENVIRONMENT_NAME must be set}"

target="${STACK_DIR%/}/environment.auto.tfvars.json"

entries=()
entries+=("\"environment_name\": \"${ENVIRONMENT_NAME}\"")

add_optional() {
    local variable="$1" value="$2"
    if [ -n "$value" ]; then
        entries+=("\"${variable}\": \"${value}\"")
    fi
}

add_optional base_domain "${LDES_BASE_DOMAIN:-}"
add_optional ldes_server_image "${LDES_SERVER_IMAGE:-}"
add_optional ldes_server_image_tag "${LDES_SERVER_IMAGE_TAG:-}"
add_optional ldio_image "${LDIO_IMAGE:-}"
add_optional ldio_image_tag "${LDIO_IMAGE_TAG:-}"

labels=()
if [ -n "${PULL_REQUEST_NUMBER:-}" ]; then
    labels+=("\"ldes.openldes.org/pull-request\": \"${PULL_REQUEST_NUMBER}\"")
fi
if [ -n "${COMMIT_SHA:-}" ]; then
    labels+=("\"ldes.openldes.org/commit\": \"${COMMIT_SHA}\"")
fi

if [ "${#labels[@]}" -gt 0 ]; then
    entries+=("\"labels\": { $(IFS=,; echo "${labels[*]}") }")
fi

printf '{ %s }\n' "$(IFS=,; echo "${entries[*]}")" > "$target"

echo "Wrote ${target}"
cat "$target"
