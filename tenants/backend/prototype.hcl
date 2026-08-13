# One state file per environment for the whole tenants layer — every cloud's
# tenants are in this state, because the cloud is a per-tenant parameter.
resource_group_name  = "rg-onek8s-tfstate"
storage_account_name = "onek8stfstate"
container_name       = "tfstate"
key                  = "tenants/prototype.tfstate"
use_azuread_auth     = true
