environment = "prototype"

# The Azure Storage state home. The foundation states this stack reads back are
# addressed by convention — foundations/<cloud>/prototype.tfstate in this same
# account and container — so there are no per-cloud coordinates to keep in sync
# with foundations/<cloud>/backend/prototype.hcl. The hub's own state
# (foundations/azure), which is where the Portainer URL comes from, is read the
# same way.
state_home = {
  resource_group_name  = "rg-onek8s-tfstate"
  storage_account_name = "onek8stfstate"
  container_name       = "tfstate"
}

# Clusters onboarded into the Portainer server on AKS, keyed by cloud. Azure is
# never listed: Portainer runs on that cluster and manages it directly, so it
# appears in the UI without an agent.
#
# Every default is taken here — one Edge Agent per cluster in the "portainer"
# namespace, bound to cluster-admin, named after its cloud. See
# modules/portainer-agent/README.md for what that grant covers and why.
agents = {
  aws = {}
  gcp = {}
  oci = {}
}
