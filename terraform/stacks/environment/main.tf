locals {
  namespace = coalesce(var.namespace, "ldes-${var.environment_name}")

  # The stream catalogue is shared with the load test and the validation scripts, so it lives in
  # the repository root rather than in this stack.
  streams_catalog = jsondecode(file(coalesce(var.streams_catalog_file, "${path.module}/../../../catalog/streams.json")))

  # PostgreSQL identifiers do not allow dashes without quoting, so the DNS label is folded into
  # an identifier friendly form for the per-environment database names.
  database_suffix = replace(var.environment_name, "-", "_")

  managed_database = var.use_managed_database && try(local.platform.database_enabled, false)

  load_balancer_ip = try(local.addons.load_balancer_ip, "")

  # nip.io resolves a name that embeds an IP address to that address, which gives every
  # environment its own hostname without having to manage DNS records.
  #
  # The address must be written with dashes: nip.io scans the name for the first dotted quad it
  # can find, so "pr-1.141.94.235.166.nip.io" resolves to 1.141.94.235 instead of 141.94.235.166
  # because the trailing "1" of the environment name is swallowed into the address. The dashed
  # form "pr-1.141-94-235-166.nip.io" is unambiguous.
  nip_io_host = "${var.environment_name}.${replace(local.load_balancer_ip, ".", "-")}.nip.io"

  ingress_host = var.base_domain != null ? "${var.environment_name}.${var.base_domain}" : local.nip_io_host

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
      # nip.io can only encode an IPv4 address, so a load balancer that is only published under a
      # hostname needs a real wildcard domain to give every environment a distinct hostname.
      condition     = var.base_domain != null || local.load_balancer_ip != ""
      error_message = "The addons stack has no load balancer IPv4 address recorded yet, so no nip.io hostname can be derived. Re-run the Platform workflow once OVHcloud finished provisioning the load balancer, or set base_domain."
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

  streams_catalog   = local.streams_catalog
  ldes_client_state = var.ldes_client_state

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
