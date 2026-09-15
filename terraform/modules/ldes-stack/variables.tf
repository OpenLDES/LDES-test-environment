variable "namespace" {
  description = "Kubernetes namespace the LDES server and LDIO are deployed in."
  type        = string
}

variable "create_namespace" {
  description = "Create the namespace. Disable when it is managed elsewhere."
  type        = bool
  default     = true
}

variable "labels" {
  description = "Labels applied to every resource created by this module."
  type        = map(string)
  default     = {}
}

# --------------------------------------------------------------------------------------------
# Charts
# --------------------------------------------------------------------------------------------

variable "chart_repository" {
  description = "Helm repository hosting the OpenLDES charts."
  type        = string
  default     = "https://openldes.github.io/helm-charts"
}

variable "ldes_server_release_name" {
  description = "Helm release name of the LDES server. Also used as the resource name prefix inside the namespace."
  type        = string
  default     = "openldes-server"
}

variable "ldes_server_chart_version" {
  description = "Version of the openldes-server Helm chart."
  type        = string
  default     = "0.3.1"
}

variable "ldes_server_image" {
  description = "Container image for the LDES server. The chart defaults to the floating \"latest\" tag, which is pinned here for reproducible test runs."

  type = object({
    repository  = optional(string, "openldes/ldes-server")
    tag         = optional(string, "4.0.0")
    pull_policy = optional(string, "IfNotPresent")
  })

  default = {}
}

variable "ldio_release_name" {
  description = "Helm release name of the LDI Orchestrator."
  type        = string
  default     = "openldes-ldio"
}

variable "ldio_chart_version" {
  description = "Version of the openldes-ldio Helm chart."
  type        = string
  default     = "0.1.1"
}

variable "ldio_image" {
  description = "Container image for the LDI Orchestrator."

  type = object({
    repository  = optional(string, "openldes/ldi-orchestrator")
    tag         = optional(string, "3.1.1")
    pull_policy = optional(string, "IfNotPresent")
  })

  default = {}
}

variable "helm_atomic" {
  description = <<-EOT
    Roll a Helm release back when it fails. Disabled by default so that a failed deployment
    leaves its pods and events behind for the diagnostics step of the pull request workflow;
    the whole namespace is thrown away at the end of a run anyway.
  EOT

  type    = bool
  default = false
}

variable "helm_timeout" {
  description = "Timeout in seconds for the Helm releases. The LDES server needs a few minutes to run its database migrations on a cold database."
  type        = number
  default     = 900
}

# --------------------------------------------------------------------------------------------
# LDES server
# --------------------------------------------------------------------------------------------

variable "ldes_server_host_name" {
  description = <<-EOT
    Public base URL of the LDES server, without trailing slash. It ends up in every fragment and
    relation URI, so it must be resolvable by the LDES client inside LDIO and by the load test.
  EOT

  type = string

  validation {
    condition     = can(regex("^https?://[^/].*[^/]$", var.ldes_server_host_name))
    error_message = "ldes_server_host_name must be an http(s) URL without a trailing slash."
  }
}

variable "event_stream_name" {
  description = "Name of the event stream created on the LDES server at startup."
  type        = string
  default     = "loadtest"

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.event_stream_name))
    error_message = "event_stream_name must be lowercase alphanumeric characters or '-'."
  }
}

variable "view_name" {
  description = "Name of the paged view created on the event stream. This is the view LDIO replicates from."
  type        = string
  default     = "by-page"
}

variable "view_page_size" {
  description = "Number of members per fragment in the paged view."
  type        = number
  default     = 250
}

variable "ldes_server_streams" {
  description = <<-EOT
    Full override for the chart's `config.streams` value. Leave null to use the generated
    single-stream / single-view definition driven by event_stream_name and view_name.
  EOT

  type    = any
  default = null
}

variable "ldes_server_replicas" {
  description = "Replica count for the LDES server. Multiple instances are not supported yet, so keep this at 1."
  type        = number
  default     = 1

  validation {
    condition     = var.ldes_server_replicas == 0 || var.ldes_server_replicas == 1
    error_message = "The LDES server does not support more than one instance; use 0 or 1."
  }
}

variable "ldes_server_resources" {
  description = "Resource requests and limits for the LDES server container."

  type = object({
    requests = optional(map(string), { cpu = "500m", memory = "1Gi" })
    limits   = optional(map(string), { cpu = "2", memory = "4Gi" })
  })

  default = {}
}

variable "ldes_server_extra_config" {
  description = "Additional configuration merged into the LDES server application.yml (chart value `config.extraConfig`)."
  type        = any
  default     = {}
}

variable "ldes_server_extra_values" {
  description = "Additional Helm values merged on top of the generated openldes-server values."
  type        = any
  default     = {}
}

# --------------------------------------------------------------------------------------------
# LDIO
# --------------------------------------------------------------------------------------------

variable "ldio_pipelines" {
  description = <<-EOT
    Full override for the chart's `config.orchestrator.pipelines` value. Leave null to use the
    generated pipeline that replicates the event stream into the PostgreSQL sink table.
  EOT

  type    = any
  default = null
}

variable "ldio_resources" {
  description = "Resource requests and limits for the LDIO container."

  type = object({
    requests = optional(map(string), { cpu = "500m", memory = "1Gi" })
    limits   = optional(map(string), { cpu = "2", memory = "4Gi" })
  })

  default = {}
}

variable "ldio_log_level" {
  description = "Root log level of the LDI Orchestrator."
  type        = string
  default     = "WARN"
}

variable "ldes_client_state" {
  description = "Persistence strategy of the LDES client inside LDIO: memory, sqlite or postgres."
  type        = string
  default     = "postgres"

  validation {
    condition     = contains(["memory", "sqlite", "postgres"], var.ldes_client_state)
    error_message = "ldes_client_state must be one of memory, sqlite or postgres."
  }
}

variable "ldio_extra_values" {
  description = "Additional Helm values merged on top of the generated openldes-ldio values."
  type        = any
  default     = {}
}

variable "ldio_ldes_server_url" {
  description = <<-EOT
    Base URL the LDES client inside LDIO replicates from. Defaults to ldes_server_host_name,
    which is also the base of every fragment and relation URI the server emits.
  EOT

  type    = string
  default = null
}

variable "member_vocabulary" {
  description = "Namespace IRI of the member properties the default SPARQL sink query selects. Must match the payload produced by the load test."
  type        = string
  default     = "https://openldes.org/ns/loadtest#"
}

# --------------------------------------------------------------------------------------------
# Databases
# --------------------------------------------------------------------------------------------

variable "ldes_server_database" {
  description = <<-EOT
    Connection details of the PostgreSQL database backing the LDES server. Set together with
    ldio_database, or leave both null to deploy a throwaway in-cluster PostgreSQL instead.
  EOT

  type = object({
    host     = string
    port     = number
    database = string
    username = string
    password = string
    ssl_mode = optional(string, "require")
  })

  default   = null
  sensitive = true
}

variable "ldio_database" {
  description = "Connection details of the PostgreSQL database LDIO writes the replicated members into."

  type = object({
    host     = string
    port     = number
    database = string
    username = string
    password = string
    ssl_mode = optional(string, "require")
  })

  default   = null
  sensitive = true

  validation {
    condition     = (var.ldes_server_database == null) == (var.ldio_database == null)
    error_message = "ldes_server_database and ldio_database must either both be set or both be null."
  }
}

variable "in_cluster_postgres" {
  description = "Settings for the throwaway in-cluster PostgreSQL, only used when no external databases are supplied."

  type = object({
    image             = optional(string, "postgres:16-alpine")
    storage           = optional(string, "8Gi")
    storage_class     = optional(string)
    server_database   = optional(string, "ldes_server")
    ldio_database     = optional(string, "ldio")
    username          = optional(string, "ldes")
    resource_requests = optional(map(string), { cpu = "250m", memory = "512Mi" })
    resource_limits   = optional(map(string), { cpu = "2", memory = "2Gi" })
  })

  default = {}
}

variable "sink_table_name" {
  description = "Name of the table LDIO writes the replicated members into."
  type        = string
  default     = "ldes_members"

  validation {
    condition     = can(regex("^[a-z_][a-z0-9_]*$", var.sink_table_name))
    error_message = "sink_table_name must be a plain lowercase PostgreSQL identifier."
  }
}

variable "sink_table_ddl" {
  description = <<-EOT
    DDL executed before LDIO starts. Ldio:LdioRdbOut requires the target table to exist and maps
    SPARQL variable names onto column names. Leave null to use the DDL matching the default
    pipeline and the bundled load test payload.
  EOT

  type    = string
  default = null
}

variable "sink_sparql_query" {
  description = "SPARQL SELECT query used by Ldio:LdioRdbOut to flatten members into table rows. Leave null to use the default matching sink_table_ddl."
  type        = string
  default     = null
}

# --------------------------------------------------------------------------------------------
# Ingress
# --------------------------------------------------------------------------------------------

variable "ingress" {
  description = "Ingress exposing the LDES server. The load test and the PR feedback rely on it."

  type = object({
    enabled     = optional(bool, true)
    class_name  = optional(string, "nginx")
    host        = optional(string)
    annotations = optional(map(string), {})
    tls_secret  = optional(string)
  })

  default = {}

  validation {
    condition     = !coalesce(var.ingress.enabled, true) || try(length(var.ingress.host) > 0, false)
    error_message = "ingress.host must be set when the ingress is enabled."
  }
}
