terraform {
  required_version = ">= 1.9.0"

  required_providers {
    # One cluster, one provider configuration: everything this module creates
    # lives on the cluster being onboarded. The Portainer side of the
    # registration is the portainer provider's business, in the caller.
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 3.0.0"
    }
  }
}
