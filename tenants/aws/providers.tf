provider "aws" {
  region = var.region

  default_tags {
    tags = {
      environment = var.environment
      managed-by  = "terraform"
      stack       = "tenants-aws"
    }
  }
}

provider "kubernetes" {
  host                   = data.terraform_remote_state.foundation.outputs.cluster_endpoint
  cluster_ca_certificate = base64decode(data.terraform_remote_state.foundation.outputs.cluster_ca_certificate)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", data.terraform_remote_state.foundation.outputs.cluster_name]
  }
}
