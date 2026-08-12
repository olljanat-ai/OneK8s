cloud       = "gcp"
environment = "dev"

foundation_state = {
  bucket = "onek8s-tfstate"
  prefix = "foundations/gcp/dev"
}

# Example tenants — identical syntax on every cloud.
tenants = {
  team-alpha = {
    quota = {
      cpu_requests    = "2"
      cpu_limits      = "4"
      memory_requests = "4Gi"
      memory_limits   = "8Gi"
    }
    labels = { "onek8s-io-cost-center" = "alpha-1001" }
  }
  team-beta = {}
}
