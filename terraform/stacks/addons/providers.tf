# The cluster is created by the platform stack. Keeping the cluster and the in-cluster add-ons in
# separate states means the kubernetes and helm providers are always configured from values that
# are already known at plan time, instead of from resources created in the same run.
data "terraform_remote_state" "platform" {
  backend = "s3"
  config  = var.platform_remote_state
}

locals {
  platform = data.terraform_remote_state.platform.outputs
}

provider "kubernetes" {
  host                   = local.platform.cluster_host
  cluster_ca_certificate = local.platform.cluster_ca_certificate
  client_certificate     = local.platform.cluster_client_certificate
  client_key             = local.platform.cluster_client_key
}

provider "helm" {
  kubernetes = {
    host                   = local.platform.cluster_host
    cluster_ca_certificate = local.platform.cluster_ca_certificate
    client_certificate     = local.platform.cluster_client_certificate
    client_key             = local.platform.cluster_client_key
  }
}
