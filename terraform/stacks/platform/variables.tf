variable "service_name" {
  description = "ID of the OVHcloud Public Cloud project. Provided through TF_VAR_service_name / the OVH_CLOUD_PROJECT_SERVICE secret."
  type        = string
}

variable "name_prefix" {
  description = "Prefix for every resource name created by this stack."
  type        = string
  default     = "ldes-test"
}

variable "region" {
  description = "OVHcloud Public Cloud region for the Kubernetes cluster, e.g. GRA11."
  type        = string
  default     = "GRA9"
}

variable "database_region" {
  description = "OVHcloud region for the managed PostgreSQL cluster. Usually the region of the Kubernetes cluster without the trailing index, e.g. GRA."
  type        = string
  default     = "GRA"
}

variable "kubernetes_version" {
  description = "Kubernetes minor version, e.g. \"1.31\". Leave null for the latest version offered by OVHcloud."
  type        = string
  default     = null
}

variable "cluster_plan" {
  description = "MKS plan: \"free\" or \"standard\"."
  type        = string
  default     = "free"
}

variable "node_pools" {
  description = "Node pools of the test cluster. The defaults hold a handful of concurrent pull request environments."

  type = map(object({
    flavor_name        = string
    desired_nodes      = optional(number, 2)
    min_nodes          = optional(number, 1)
    max_nodes          = optional(number, 5)
    autoscale          = optional(bool, false)
    anti_affinity      = optional(bool, false)
    monthly_billed     = optional(bool, false)
    availability_zones = optional(list(string))
  }))

  default = {
    workers = {
      flavor_name   = "b3-8"
      desired_nodes = 3
      min_nodes     = 2
      max_nodes     = 8
      autoscale     = true
    }
  }
}

variable "api_server_ip_restrictions" {
  description = "CIDRs allowed to reach the Kubernetes API server. Empty means no restriction, which is required for hosted GitHub Actions runners."
  type        = list(string)
  default     = []
}

variable "create_database" {
  description = "Create a managed PostgreSQL cluster shared by all test environments. Disable to fall back on a throwaway in-cluster PostgreSQL per environment."
  type        = bool
  default     = true
}

variable "database_version" {
  description = "PostgreSQL major version of the managed cluster."
  type        = string
  default     = "16"
}

variable "database_plan" {
  description = "Plan of the managed PostgreSQL cluster."
  type        = string
  default     = "essential"
}

variable "database_flavor" {
  description = "Flavor of the managed PostgreSQL cluster."
  type        = string
  default     = "db1-4"
}

variable "database_nodes_count" {
  description = "Number of nodes in the managed PostgreSQL cluster. The essential plan only supports one."
  type        = number
  default     = 1
}

variable "database_disk_size" {
  description = "Disk size in GB of the managed PostgreSQL cluster. Leave null for the flavor default."
  type        = number
  default     = null
}

variable "database_ip_restrictions" {
  description = <<-EOT
    CIDRs allowed to reach the managed PostgreSQL cluster, keyed by a description.

    The cluster nodes reach the database over their public egress addresses, which are not known
    up front on OVHcloud Public Cloud, hence the permissive default. Narrow this down to the
    cluster egress ranges (or attach both to a vRack) for anything beyond a test environment.
  EOT

  type = map(string)

  default = {
    "any" = "0.0.0.0/0"
  }
}
