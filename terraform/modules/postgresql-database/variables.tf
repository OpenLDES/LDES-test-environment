variable "service_name" {
  description = "The ID of the OVHcloud Public Cloud project that owns the database cluster."
  type        = string
}

variable "cluster_id" {
  description = "ID of the managed PostgreSQL cluster to create the database in."
  type        = string
}

variable "name" {
  description = "Name of the logical database to create."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9_]+$", var.name))
    error_message = "Database names must consist of lowercase letters, digits and underscores."
  }
}

variable "host" {
  description = "Hostname of the PostgreSQL cluster endpoint."
  type        = string
}

variable "port" {
  description = "Port of the PostgreSQL cluster endpoint."
  type        = number
}

variable "ssl_mode" {
  description = "sslmode used in the generated connection strings."
  type        = string
  default     = "require"
}

variable "admin_username" {
  description = "Cluster superuser name (\"avnadmin\" on OVHcloud)."
  type        = string
}

variable "admin_password" {
  description = "Cluster superuser password."
  type        = string
  sensitive   = true
}

variable "create_user" {
  description = <<-EOT
    Provision a dedicated, non-privileged user next to the database.

    Disabled by default: OVHcloud (Aiven) PostgreSQL does not grant a freshly created user any
    privileges on the `public` schema of an existing database, so the LDES server would not be
    able to create its own tables. With this disabled the applications connect using the cluster
    superuser, while isolation between environments is still provided by the separate database.
  EOT

  type    = bool
  default = false
}

variable "user_name" {
  description = "Name of the dedicated user. Defaults to the database name. Only used when create_user is true."
  type        = string
  default     = null
}
