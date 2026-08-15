# The Azure Storage state home holds every stack's state, on every cloud — the
# private cloud included. Bootstrap the storage account once, out of band.
resource_group_name  = "rg-onek8s-tfstate"
storage_account_name = "onek8stfstate"
container_name       = "tfstate"
key                  = "foundations/nutanix/prototype.tfstate"
use_azuread_auth     = true
