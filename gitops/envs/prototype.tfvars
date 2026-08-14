environment = "prototype"

# The Azure Storage state home. The foundation states this stack reads back are
# addressed by convention — foundations/<cloud>/prototype.tfstate in this same
# account and container — so there are no per-cloud coordinates to keep in sync
# with foundations/<cloud>/backend/prototype.hcl. The hub's own state
# (foundations/azure) is read the same way.
state_home = {
  resource_group_name  = "rg-onek8s-tfstate"
  storage_account_name = "onek8stfstate"
  container_name       = "tfstate"
}

# Clusters registered with the Argo CD hub on AKS, keyed by cloud. Azure is
# never listed: Argo CD already has the in-cluster entry for the cluster it
# runs on.
#
# The prototype spokes are unrestricted — no namespace list, cluster-scoped
# resources allowed — because this environment is where platform-wide
# manifests get tried out. Narrow a spoke with
# `namespaces = [...]` + `cluster_resources = false`, which binds the manager
# ServiceAccount per namespace instead of cluster-wide.
spokes = {
  aws = {}
  gcp = {}
  oci = {}
}

# The root Application: the only Argo CD object Terraform creates. It points
# Argo CD at gitops/argocd/ in this repository, and everything from there down
# — the AppProject, the ApplicationSets, and every Application they generate on
# the hub and on each spoke — is Git, not Terraform.
#
# The values below are what make one copy of gitops/argocd/ serve every
# environment: they are handed to that chart as Helm values, so the spoke
# selector, the hosts and the tenant follow the environment rather than being
# committed per environment.
platform_apps = {
  repo_url        = "https://github.com/olljanat-ai/OneK8s.git"
  target_revision = "main"

  # Where the example application lands. team-alpha exists on all four clouds
  # in this environment (tenants/envs/prototype.tfvars), and its namespaced
  # SecretStore is what the app reads its test secret through.
  tenant = "team-alpha"

  # Application hosts are "<cloud>-<app>.onek8s.lol", one label deep, which is
  # all the platform wildcard covers.
  domain = "onek8s.lol"
}
