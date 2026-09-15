variable "service_name" {
  description = "The ID of the OVHcloud Public Cloud project the cluster is created in."
  type        = string
}

variable "name" {
  description = "Name of the Managed Kubernetes Service (MKS) cluster. Underscores are not allowed."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.name))
    error_message = "The cluster name must be lowercase alphanumeric characters or '-', and must start and end with an alphanumeric character."
  }
}

variable "region" {
  description = "OVHcloud Public Cloud region the cluster is deployed in, e.g. GRA11 or WAW1."
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes minor version to deploy, e.g. \"1.31\". Leave null to use the latest version offered by OVHcloud."
  type        = string
  default     = null
}

variable "plan" {
  description = "MKS plan. \"free\" gives a non-SLA control plane, \"standard\" a highly available one."
  type        = string
  default     = "free"

  validation {
    condition     = contains(["free", "standard"], var.plan)
    error_message = "plan must be either \"free\" or \"standard\"."
  }
}

variable "update_policy" {
  description = "Cluster update policy: ALWAYS_UPDATE, MINIMAL_DOWNTIME or NEVER_UPDATE."
  type        = string
  default     = "MINIMAL_DOWNTIME"

  validation {
    condition     = contains(["ALWAYS_UPDATE", "MINIMAL_DOWNTIME", "NEVER_UPDATE"], var.update_policy)
    error_message = "update_policy must be one of ALWAYS_UPDATE, MINIMAL_DOWNTIME or NEVER_UPDATE."
  }
}

variable "kube_proxy_mode" {
  description = "kube-proxy mode, either \"iptables\" or \"ipvs\"."
  type        = string
  default     = "iptables"

  validation {
    condition     = contains(["iptables", "ipvs"], var.kube_proxy_mode)
    error_message = "kube_proxy_mode must be either \"iptables\" or \"ipvs\"."
  }
}

variable "private_network_id" {
  description = "Optional private network (vRack) ID to attach the cluster to. Changing this resets the cluster."
  type        = string
  default     = null
}

variable "nodes_subnet_id" {
  description = "Optional subnet ID used for the nodes. Requires private_network_id."
  type        = string
  default     = null
}

variable "load_balancers_subnet_id" {
  description = "Optional subnet ID used for public load balancers. Requires private_network_id."
  type        = string
  default     = null
}

variable "api_server_ip_restrictions" {
  description = "CIDRs allowed to reach the Kubernetes API server. An empty list disables the restriction (API server reachable from anywhere)."
  type        = list(string)
  default     = []
}

variable "node_pools" {
  description = <<-EOT
    Node pools to create on the cluster, keyed by pool name. The key is used as the node pool
    name and must not contain underscores.
  EOT

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
      desired_nodes = 2
      min_nodes     = 2
      max_nodes     = 5
      autoscale     = true
    }
  }

  validation {
    condition     = alltrue([for name in keys(var.node_pools) : can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", name))])
    error_message = "Node pool names must be lowercase alphanumeric characters or '-'. Underscores are not allowed by the OVHcloud API."
  }

  validation {
    condition     = alltrue([for pool in values(var.node_pools) : pool.min_nodes <= pool.desired_nodes && pool.desired_nodes <= pool.max_nodes])
    error_message = "Every node pool must satisfy min_nodes <= desired_nodes <= max_nodes."
  }
}
