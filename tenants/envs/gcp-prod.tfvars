cloud       = "gcp"
environment = "prod"

foundation_state = {
  bucket = "onek8s-tfstate"
  prefix = "foundations/gcp/prod"
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
