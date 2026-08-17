# One state file per environment for the whole Portainer layer — every
# onboarded cluster of every cloud is in this state, because the cloud is a key
# of var.agents.
resource_group_name  = "rg-onek8s-tfstate"
storage_account_name = "onek8stfstate"
container_name       = "tfstate"
key                  = "portainer/prototype.tfstate"
use_azuread_auth     = true
