terraform {
  required_version = ">= 1.9.0"

  required_providers {
    # The private cloud's IAM plane. It is the only one of the five that is a
    # product rather than a cloud API, and the only one where the platform
    # operates the identity provider itself.
    vault = {
      source  = "hashicorp/vault"
      version = "= 5.11.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "= 3.2.1"
    }
  }
}
