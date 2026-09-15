variable "platform_remote_state" {
  description = "Backend configuration used to read the outputs of the platform stack. Typed loosely because the S3 backend takes nested attributes such as `endpoints.s3`."
  type        = any
}

variable "addons_remote_state" {
  description = "Backend configuration used to read the outputs of the addons stack."
  type        = any
}

variable "environment_name" {
  description = <<-EOT
    Name of the test environment. The pull request workflow passes "pr-<number>". It is used for
    the namespace, the ingress hostname and the per-environment database names, so it must be a
    valid DNS label.
  EOT

  type = string

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]{0,30}[a-z0-9])?$", var.environment_name))
    error_message = "environment_name must be a DNS label of at most 32 characters: lowercase alphanumerics and '-'."
  }
}

variable "namespace" {
  description = "Namespace for the environment. Defaults to ldes-<environment_name>."
  type        = string
  default     = null
}

variable "base_domain" {
  description = <<-EOT
    Domain the environment hostname is built under, as "<environment_name>.<base_domain>".

    Leave null to derive a hostname from the ingress load balancer address through nip.io, which
    removes the need to own or manage DNS for throwaway pull request environments.
  EOT

  type    = string
  default = null
}

variable "tls_secret_name" {
  description = "Name of an existing TLS secret in the environment namespace to terminate HTTPS with. Leave null to serve plain HTTP."
  type        = string
  default     = null
}

variable "use_managed_database" {
  description = <<-EOT
    Use the shared managed PostgreSQL cluster from the platform stack. When disabled (or when the
    platform stack has no database) a throwaway PostgreSQL is deployed inside the environment
    namespace instead, which is cheaper but loses its data when the environment is destroyed.
  EOT

  type    = bool
  default = true
}

variable "event_stream_name" {
  description = "Name of the event stream created on the LDES server."
  type        = string
  default     = "loadtest"
}

variable "view_name" {
  description = "Name of the paged view LDIO replicates from."
  type        = string
  default     = "by-page"
}

variable "view_page_size" {
  description = "Number of members per fragment in the paged view."
  type        = number
  default     = 250
}

variable "ldes_server_chart_version" {
  description = "Version of the openldes-server Helm chart."
  type        = string
  default     = "0.3.1"
}

variable "ldio_chart_version" {
  description = "Version of the openldes-ldio Helm chart."
  type        = string
  default     = "0.1.1"
}

variable "ldes_server_image_tag" {
  description = "Image tag of the LDES server under test. The pull request workflow can override this with a candidate build."
  type        = string
  default     = "4.0.0"
}

variable "ldio_image_tag" {
  description = "Image tag of the LDI Orchestrator under test."
  type        = string
  default     = "3.1.1"
}

variable "ldes_server_resources" {
  description = "Resource requests and limits for the LDES server container."

  type = object({
    requests = optional(map(string), { cpu = "500m", memory = "1Gi" })
    limits   = optional(map(string), { cpu = "2", memory = "4Gi" })
  })

  default = {}
}

variable "ldio_resources" {
  description = "Resource requests and limits for the LDIO container."

  type = object({
    requests = optional(map(string), { cpu = "500m", memory = "1Gi" })
    limits   = optional(map(string), { cpu = "2", memory = "4Gi" })
  })

  default = {}
}

variable "labels" {
  description = "Extra labels applied to every resource, e.g. to record the pull request that owns the environment."
  type        = map(string)
  default     = {}
}
