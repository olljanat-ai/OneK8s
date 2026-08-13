# One state file per environment for the whole GitOps layer — the hub and
# every spoke are in this state, because a hub-spoke topology is one thing, not
# four.
resource_group_name  = "rg-onek8s-tfstate"
storage_account_name = "onek8stfstate"
container_name       = "tfstate"
key                  = "gitops/prototype.tfstate"
use_azuread_auth     = true
