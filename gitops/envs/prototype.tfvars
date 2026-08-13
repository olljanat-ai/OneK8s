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
}
