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

output "event_stream_name" {
  description = "Name of the event stream created on the LDES server."
  value       = var.event_stream_name
}

output "ingest_url" {
  description = "URL the load test posts members to."
  value       = local.event_stream_url
}

output "view_url" {
  description = "URL of the paged view LDIO replicates from."
  value       = local.view_url
}

output "admin_url" {
  description = "Base URL of the LDES server admin API."
  value       = "${local.ldes_server_public_url}/admin/api/v1"
}

output "member_vocabulary" {
  description = "Namespace IRI the default SPARQL sink query expects the member properties in."
  value       = var.member_vocabulary
}

output "sink_table_name" {
  description = "Table LDIO writes the replicated members into."
  value       = var.sink_table_name
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
