data "terraform_remote_state" "platform" {
  backend = "s3"
  config  = var.platform_remote_state
}

data "terraform_remote_state" "addons" {
  backend = "s3"
  config  = var.addons_remote_state
}

locals {
  platform = data.terraform_remote_state.platform.outputs
  addons   = data.terraform_remote_state.addons.outputs
}

provider "ovh" {}

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
