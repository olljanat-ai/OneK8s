# Three planes, three sets of credentials, none of them a cloud's:
#
#   kubernetes.nkp   the NKP management cluster — a ServiceAccount token
#   kubernetes/helm  the workload cluster — its Cluster API kubeconfig, read
#                    back from the management cluster (modules/nkp-cluster-access)
#   vault            the secret backend — VAULT_TOKEN from the environment
#
# There is deliberately no nutanix provider and no Prism Central credential
# here. NKP owns the cluster's lifecycle and holds those credentials itself;
# this stack drives it through its own Kubernetes API.
provider "kubernetes" {
  alias = "nkp"

  host                   = var.nkp_management_host
  token                  = var.nkp_management_token
  cluster_ca_certificate = var.nkp_management_ca_certificate == "" ? null : base64decode(var.nkp_management_ca_certificate)
}

# The workload cluster. Unknown at plan time on a cold apply — the kubeconfig
# Secret does not exist until Cluster API has written it — which is why the
# module below is ordered after the cluster manifests and why nothing in this
# stack reads the cluster with a data source.
provider "kubernetes" {
  host                   = module.cluster.host
  cluster_ca_certificate = base64decode(module.cluster.cluster_ca_certificate)
  client_certificate     = try(base64decode(module.cluster.client_certificate), null)
  client_key             = try(base64decode(module.cluster.client_key), null)
  token                  = module.cluster.token
}

provider "helm" {
  kubernetes = {
    host                   = module.cluster.host
    cluster_ca_certificate = base64decode(module.cluster.cluster_ca_certificate)
    client_certificate     = try(base64decode(module.cluster.client_certificate), null)
    client_key             = try(base64decode(module.cluster.client_key), null)
    token                  = module.cluster.token
  }
}

# The token comes from VAULT_TOKEN (or ~/.vault-token locally); it is never
# configuration. skip_child_token stops the provider from minting a child
# token per run: the runs are short, and a private-cloud Vault is often
# reached through an operator token that may not carry the create-child
# capability.
provider "vault" {
  address          = var.vault_address
  namespace        = var.vault_namespace == "" ? null : var.vault_namespace
  skip_child_token = true
}
