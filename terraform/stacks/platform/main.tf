module "kubernetes" {
  source = "../../modules/kubernetes"

  service_name = var.service_name
  name         = "${var.name_prefix}-cluster"
  region       = var.region

  kubernetes_version = var.kubernetes_version
  plan               = var.cluster_plan

  api_server_ip_restrictions = var.api_server_ip_restrictions
  node_pools                 = var.node_pools
}

module "postgresql" {
  source = "../../modules/postgresql"
  count  = var.create_database ? 1 : 0

  service_name = var.service_name
  description  = "${var.name_prefix}-postgresql"

  region         = var.database_region
  engine_version = var.database_version
  plan           = var.database_plan
  flavor         = var.database_flavor
  nodes_count    = var.database_nodes_count
  disk_size      = var.database_disk_size

  ip_restrictions = var.database_ip_restrictions

  admin_password_reset = var.database_admin_password_reset
}
