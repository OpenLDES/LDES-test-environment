terraform {
  required_version = ">= 1.9.0"

  required_providers {
    ovh = {
      source  = "ovh/ovh"
      version = "~> 2.0"
    }
  }

  # Partial configuration: the remaining settings come from a -backend-config file so that no
  # environment specific values or credentials end up in version control.
  # See docs/backend.hcl.example.
  backend "s3" {}
}
