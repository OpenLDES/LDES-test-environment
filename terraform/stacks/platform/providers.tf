# Credentials are never declared here. The provider reads OVH_ENDPOINT plus either the
# OVH_APPLICATION_KEY / OVH_APPLICATION_SECRET / OVH_CONSUMER_KEY triplet or the OAuth2
# OVH_CLIENT_ID / OVH_CLIENT_SECRET pair from the environment, which is how GitHub Actions
# injects the repository secrets.
provider "ovh" {}
