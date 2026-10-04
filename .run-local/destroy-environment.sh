#!/usr/bin/env bash
#
# Tears the local test environment down: the LDES deployment of ENVIRONMENT_NAME, the add-ons and
# the platform, in that order. The same thing the Platform workflow does in destroy mode, with the
# environment cleanup of pr-test-environment-cleanup.yml in front of it, minus GitHub.
#
# Usage: .run-local/destroy-environment.sh
#
# Everything is destroyed without asking: the script does one thing and its name says what.
#
# Credentials and the environment name come from .run-local/configuration.sh; the OVHcloud project
# and the cluster shape come from terraform/stacks/platform/terraform.tfvars, exactly as in a local
# apply. Nothing is read from the environment of the calling shell.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=./configuration.sh
source "${SCRIPT_DIR}/configuration.sh"

: "${ENVIRONMENT_NAME:?ENVIRONMENT_NAME must be set in configuration.sh}"

# Terraform must never stop on a prompt here: every destroy below passes -auto-approve, and an
# unanswerable "var.x: Enter a value" would otherwise hang the script.
export TF_IN_AUTOMATION='true'
export TF_INPUT='0'

command -v terraform >/dev/null 2>&1 || {
    echo "Terraform is not on the PATH." >&2
    exit 1
}

# Initialises one stack against its own state object in the remote state bucket. -reconfigure keeps
# a stale .terraform/terraform.tfstate from a previous run pointing at another key out of the way.
init_stack() {
    local stack="$1" state_key="$2"

    "${REPO_ROOT}/scripts/write-backend-config.sh" "terraform/stacks/${stack}" "${state_key}"
    terraform -chdir="terraform/stacks/${stack}" init -input=false -reconfigure -backend-config=backend.hcl
}

resource_count() {
    terraform -chdir="terraform/stacks/$1" state list 2>/dev/null | grep -c . || true
}

cd "${REPO_ROOT}"

echo "==> Reading the platform state"
init_stack platform platform/terraform.tfstate

# `terraform output` exits 0 with only a warning when the state is empty, so the emptiness of the
# cluster ID is what tells us the platform was never applied or is already gone.
cluster_id="$(terraform -chdir=terraform/stacks/platform output -raw cluster_id 2>/dev/null || true)"

if [ -z "${cluster_id}" ]; then
    echo "The platform is not running: no cluster is recorded in ${TF_STATE_BUCKET}/platform/terraform.tfstate."
    echo "Nothing to destroy."
    exit 0
fi

cluster_name="$(terraform -chdir=terraform/stacks/platform output -raw cluster_name 2>/dev/null || true)"

echo "Platform is running: cluster ${cluster_name:-unknown} (${cluster_id})."
echo "Destroying the ${ENVIRONMENT_NAME} environment, the add-ons and the platform."

# The environment runs on the cluster and hangs its Ingress off the add-ons ingress class, so it
# has to go first. Destroying the cluster underneath it would leave its state describing resources
# that no longer exist, which the next apply of the same environment name then trips over.
echo
echo "==> Destroying the ${ENVIRONMENT_NAME} environment"
init_stack environment "environments/${ENVIRONMENT_NAME}/terraform.tfstate"
./scripts/write-remote-state-vars.sh terraform/stacks/environment platform addons
./scripts/write-environment-vars.sh terraform/stacks/environment

if [ "$(resource_count environment)" -eq 0 ]; then
    echo "No resources tracked for ${ENVIRONMENT_NAME}, skipping."
else
    terraform -chdir=terraform/stacks/environment destroy -auto-approve -lock-timeout=10m
fi

# The ingress controller owns an OVHcloud load balancer that is not tracked by the platform stack.
# Removing the add-ons first releases it; destroying the cluster underneath would orphan it and
# leave a billed public IP behind.
echo
echo "==> Destroying the add-ons"
init_stack addons addons/terraform.tfstate
./scripts/write-remote-state-vars.sh terraform/stacks/addons platform

if [ "$(resource_count addons)" -eq 0 ]; then
    echo "No resources tracked in the add-ons state, skipping."
else
    terraform -chdir=terraform/stacks/addons destroy -auto-approve -lock-timeout=5m
fi

echo
echo "==> Destroying the platform"
terraform -chdir=terraform/stacks/platform destroy -auto-approve -lock-timeout=10m

echo
echo "The platform is destroyed. Run .run-local/create-environment-and-run-loadtest.sh to bring it back."
