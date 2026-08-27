# Authentication: GitHub Actions uses IAM user access keys from GitHub
# secrets (aws-actions/configure-aws-credentials); locally use your AWS
# profile.
provider "aws" {
  region = var.region

  default_tags {
    tags = {
      environment = var.environment
      managed-by  = "terraform"
      stack       = "foundations-aws"
    }
  }
}

provider "helm" {
  kubernetes = {
    host                   = aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(aws_eks_cluster.this.certificate_authority[0].data)
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", aws_eks_cluster.this.name]
    }
  }
}

# Same credentials as the helm provider, for the handful of plain Kubernetes
# objects this stack owns (the ConfigMap of cluster facts modules/fluxcd hands
# to Flux). Only ordinary resources are used, never kubernetes_manifest, so the
# cluster has to be reachable at apply time but not at plan time.
provider "kubernetes" {
  host                   = aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.this.certificate_authority[0].data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", aws_eks_cluster.this.name]
  }
}
