locals {
  namespace = coalesce(var.namespace, "ldes-${var.environment_name}")

  # PostgreSQL identifiers do not allow dashes without quoting, so the DNS label is folded into
  # an identifier friendly form for the per-environment database names.
  database_suffix = replace(var.environment_name, "-", "_")

  managed_database = var.use_managed_database && try(local.platform.database_enabled, false)

  load_balancer_hostname = try(local.addons.load_balancer_hostname, "")
  load_balancer_ip       = try(local.addons.load_balancer_ip, "")
  load_balancer_address  = local.load_balancer_hostname != "" ? local.load_balancer_hostname : local.load_balancer_ip

  # nip.io resolves <anything>.<ip>.nip.io to <ip>, which gives every environment its own
  # hostname without having to manage DNS records.
  ingress_host = var.base_domain != null ? "${var.environment_name}.${var.base_domain}" : "${var.environment_name}.${local.load_balancer_address}.nip.io"

  scheme = var.tls_secret_name != null ? "https" : "http"

  ldes_server_host_name = "${local.scheme}://${local.ingress_host}"

  labels = merge({
    "ldes.openldes.org/environment" = var.environment_name
  }, var.labels)
}

# Fails the plan with a readable message instead of letting an empty load balancer address leak
# into the ingress hostname.
resource "terraform_data" "preconditions" {
  input = local.ingress_host

  lifecycle {
    precondition {
      condition     = var.base_domain != null || local.load_balancer_address != ""
      error_message = "The addons stack has no load balancer address recorded yet, so no nip.io hostname can be derived. Re-run the Platform workflow once OVHcloud finished provisioning the load balancer, or set base_domain."
    }
  }
}

module "ldes_server_database" {
  source = "../../modules/postgresql-database"
  count  = local.managed_database ? 1 : 0

  service_name = local.platform.service_name
  cluster_id   = local.platform.database_cluster_id
  name         = "ldes_server_${local.database_suffix}"

  host     = local.platform.database_host
  port     = local.platform.database_port
  ssl_mode = local.platform.database_ssl_mode

  admin_username = local.platform.database_admin_username
  admin_password = local.platform.database_admin_password
}

module "ldio_database" {
  source = "../../modules/postgresql-database"
  count  = local.managed_database ? 1 : 0

  service_name = local.platform.service_name
  cluster_id   = local.platform.database_cluster_id
  name         = "ldio_${local.database_suffix}"

  host     = local.platform.database_host
  port     = local.platform.database_port
  ssl_mode = local.platform.database_ssl_mode

  admin_username = local.platform.database_admin_username
  admin_password = local.platform.database_admin_password
}

module "ldes_stack" {
  source = "../../modules/ldes-stack"

  namespace = local.namespace
  labels    = local.labels

  depends_on = [terraform_data.preconditions]

  ldes_server_host_name = local.ldes_server_host_name

  event_stream_name = var.event_stream_name
  view_name         = var.view_name
  view_page_size    = var.view_page_size

  ldes_server_chart_version = var.ldes_server_chart_version
  ldio_chart_version        = var.ldio_chart_version

  ldes_server_image = {
    tag = var.ldes_server_image_tag
  }

  ldio_image = {
    tag = var.ldio_image_tag
  }

  ldes_server_resources = var.ldes_server_resources
  ldio_resources        = var.ldio_resources

  ldes_server_database = local.managed_database ? {
    host     = module.ldes_server_database[0].connection.host
    port     = module.ldes_server_database[0].connection.port
    database = module.ldes_server_database[0].connection.database
    username = module.ldes_server_database[0].connection.username
    password = module.ldes_server_database[0].connection.password
    ssl_mode = module.ldes_server_database[0].connection.ssl_mode
  } : null

  ldio_database = local.managed_database ? {
    host     = module.ldio_database[0].connection.host
    port     = module.ldio_database[0].connection.port
    database = module.ldio_database[0].connection.database
    username = module.ldio_database[0].connection.username
    password = module.ldio_database[0].connection.password
    ssl_mode = module.ldio_database[0].connection.ssl_mode
  } : null

  ingress = {
    enabled    = true
    class_name = local.addons.ingress_class_name
    host       = local.ingress_host
    tls_secret = var.tls_secret_name
  }
}
