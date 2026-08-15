terraform {
  required_version = ">= 1.9.0"

  required_providers {
    # The management cluster, not the workload cluster: the caller passes the
    # provider configured against NKP, and gets back what it needs to
    # configure a second one against the cluster NKP manages.
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 3.0.0"
    }
  }
}
