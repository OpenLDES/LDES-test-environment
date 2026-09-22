output "namespace" {
  description = "Namespace the stack is deployed in."
  value       = local.namespace
}

output "ldes_server_url" {
  description = "Public base URL of the LDES server."
  value       = local.ldes_server_public_url
}

output "ldes_server_internal_url" {
  description = "Cluster-internal base URL of the LDES server."
  value       = local.ldes_server_internal_url
}

output "stream_names" {
  description = "Names of the event streams created on the LDES server."
  value       = [for stream in local.catalog.streams : stream.name]
}

output "streams" {
  description = "Per stream ingest endpoint, views and sink table, for the load test and the verification."
  value       = local.stream_endpoints
}

output "view_urls" {
  description = "Every view of every stream. The load test queries all of them, and the deployment is only ready once all of them are served."
  value       = local.view_urls
}

output "sink_tables" {
  description = "Tables LDIO replicates the members into."
  value       = local.sink_tables
}

output "sink_queries" {
  description = "Generated SPARQL SELECT queries used by Ldio:LdioRdbOut, exposed for debugging."
  value       = local.sink_queries
}

output "admin_url" {
  description = "Base URL of the LDES server admin API."
  value       = "${local.ldes_server_public_url}/admin/api/v1"
}

output "sink_database" {
  description = "Connection details of the database LDIO writes into, for verification after a load test."

  value = {
    host     = local.ldio_database.host
    port     = local.ldio_database.port
    database = local.ldio_database.database
    username = local.ldio_database.username
    password = local.ldio_database.password
    ssl_mode = coalesce(local.ldio_database.ssl_mode, "require")
    uri      = local.ldio_admin_uri
  }

  sensitive = true
}

output "ldes_server_release" {
  description = "Helm release name of the LDES server."
  value       = helm_release.ldes_server.name
}

output "ldio_release" {
  description = "Helm release name of the LDI Orchestrator."
  value       = helm_release.ldio.name
}
