resource "ovh_cloud_project_database" "this" {
  service_name = var.service_name
  description  = var.description

  engine  = "postgresql"
  version = var.engine_version
  plan    = var.plan
  flavor  = var.flavor

  disk_size           = var.disk_size
  deletion_protection = var.deletion_protection

  backup_time      = var.backup_time
  maintenance_time = var.maintenance_time

  advanced_configuration = var.advanced_configuration

  dynamic "nodes" {
    for_each = range(var.nodes_count)

    content {
      region     = var.region
      network_id = var.network_id
      subnet_id  = var.subnet_id
    }
  }

  dynamic "ip_restrictions" {
    for_each = var.ip_restrictions

    content {
      description = ip_restrictions.key
      ip          = ip_restrictions.value
    }
  }

  timeouts {
    create = "40m"
    update = "40m"
    delete = "40m"
  }
}

# Managing "avnadmin" does not create a new user: OVHcloud maps it onto the built-in superuser
# and resets its password, which is the only supported way to obtain credentials for it.
resource "ovh_cloud_project_database_postgresql_user" "admin" {
  count = var.manage_admin_user ? 1 : 0

  service_name = var.service_name
  cluster_id   = ovh_cloud_project_database.this.id
  name         = "avnadmin"
}

locals {
  # A PostgreSQL cluster exposes both the "postgresql" endpoint and, depending on the plan, a
  # connection pooler endpoint. Always prefer the direct one.
  direct_endpoints = [
    for endpoint in ovh_cloud_project_database.this.endpoints : endpoint
    if endpoint.component == "postgresql"
  ]

  endpoint = length(local.direct_endpoints) > 0 ? local.direct_endpoints[0] : ovh_cloud_project_database.this.endpoints[0]

  ssl_mode = local.endpoint.ssl ? "require" : "disable"
}
