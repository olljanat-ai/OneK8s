# Fill in with your state storage account (bootstrap it once, out of band).
resource_group_name  = "rg-onek8s-tfstate"
storage_account_name = "onek8stfstate"
container_name       = "tfstate"
key                  = "foundations/azure/dev.tfstate"
use_oidc             = true
use_azuread_auth     = true
