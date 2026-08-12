resource_group_name  = "rg-onek8s-tfstate"
storage_account_name = "onek8stfstate"
container_name       = "tfstate"
key                  = "tenants/gcp/dev.tfstate"
use_oidc             = true
use_azuread_auth     = true
