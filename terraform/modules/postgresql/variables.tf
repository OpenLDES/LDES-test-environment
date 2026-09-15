variable "service_name" {
  description = "The ID of the OVHcloud Public Cloud project the database cluster is created in."
  type        = string
}

variable "description" {
  description = "Human readable description of the database cluster."
  type        = string
}

variable "engine_version" {
  description = "PostgreSQL major version to deploy, e.g. \"16\"."
  type        = string
  default     = "16"
}

variable "plan" {
  description = "Service plan: essential, business or enterprise."
  type        = string
  default     = "essential"

  validation {
    condition     = contains(["essential", "business", "enterprise"], var.plan)
    error_message = "plan must be one of essential, business or enterprise."
  }
}

variable "flavor" {
  description = "OVHcloud database flavor, e.g. db1-4 or db1-7."
  type        = string
  default     = "db1-4"
}

variable "region" {
  description = "Region to deploy the database nodes in, e.g. GRA or WAW."
  type        = string
}

variable "nodes_count" {
  description = "Number of database nodes. The essential plan only supports a single node."
  type        = number
  default     = 1

  validation {
    condition     = var.nodes_count >= 1
    error_message = "nodes_count must be at least 1."
  }
}

variable "disk_size" {
  description = "Disk size in GB. Leave null to use the flavor default."
  type        = number
  default     = null
}

variable "network_id" {
  description = "Optional private network (openstack regional ID) to attach the nodes to."
  type        = string
  default     = null
}

variable "subnet_id" {
  description = "Optional private subnet to attach the nodes to. Requires network_id."
  type        = string
  default     = null
}

variable "ip_restrictions" {
  description = <<-EOT
    CIDRs allowed to connect to the database cluster. OVHcloud denies all traffic when this
    list is empty, so at least the egress IPs of the Kubernetes nodes must be listed.
  EOT

  type = map(string)

  default = {
    "everywhere" = "0.0.0.0/0"
  }
}

variable "backup_time" {
  description = "Time of day at which daily backups start, e.g. \"02:00:00\". Leave null for the OVHcloud default."
  type        = string
  default     = null
}

variable "maintenance_time" {
  description = "Time of day at which maintenance may start, e.g. \"03:00:00\". Leave null for the OVHcloud default."
  type        = string
  default     = null
}

variable "advanced_configuration" {
  description = "Engine specific advanced configuration key/value pairs."
  type        = map(string)
  default     = {}
}

variable "deletion_protection" {
  description = "Prevents the database cluster from being deleted through the OVHcloud API."
  type        = bool
  default     = false
}

variable "manage_admin_user" {
  description = <<-EOT
    Manage the built-in "avnadmin" superuser with Terraform so its password becomes available
    as an output. Required when other stacks need to create databases, roles or tables.
  EOT

  type    = bool
  default = true
}
