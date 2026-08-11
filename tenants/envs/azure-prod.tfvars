cloud       = "azure"
environment = "prod"

foundation_state = {
  resource_group_name  = "rg-onek8s-tfstate"
  storage_account_name = "onek8stfstate"
  container_name       = "tfstate"
  key                  = "foundations/azure/prod.tfstate"
}

tenants = {
  team-alpha = {
    quota = {
      cpu_requests    = "8"
      cpu_limits      = "16"
      memory_requests = "16Gi"
      memory_limits   = "32Gi"
      pods            = "100"
    }
  }
}
