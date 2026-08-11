environment = "staging"

foundation_state = {
  resource_group_name  = "rg-onek8s-tfstate"
  storage_account_name = "onek8stfstate"
  container_name       = "tfstate"
  key                  = "foundations/azure/staging.tfstate"
}

tenants = {
  team-alpha = {}
}
