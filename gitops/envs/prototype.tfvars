environment = "prototype"

# The Azure Storage state home. The foundation states this stack reads back are
# addressed by convention — foundations/<cloud>/prototype.tfstate in this same
# account and container.
state_home = {
  resource_group_name  = "rg-onek8s-tfstate"
  storage_account_name = "onek8stfstate"
  container_name       = "tfstate"
}

# The clusters that connect back to the hub. Azure is absent on purpose: it is
# the hub, and its own Argo CD manages that cluster directly.
#
# Each entry becomes an agent named "<cloud>-prototype", which is what an
# Application targets with spec.destination.name. A cloud left out of this map
# is untouched: no foundation state read, no cluster contacted, no credentials
# needed.
spokes = {
  aws = {}
  gcp = {}
  oci = {}
}

# The AKS Argo CD extension is left alone by default. Everything except live
# resource views works without touching it; `terraform output
# hub_extension_command` prints the one setting that does not.
manage_hub_extension = false
