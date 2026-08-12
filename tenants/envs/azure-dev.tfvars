cloud       = "azure"
environment = "dev"

foundation_state = {
  resource_group_name  = "rg-onek8s-tfstate"
  storage_account_name = "onek8stfstate"
  container_name       = "tfstate"
  key                  = "foundations/azure/dev.tfstate"
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
    limit_range = {
      default_cpu_limit    = "500m"
      default_memory_limit = "512Mi"
      max_cpu              = "2"
      max_memory           = "4Gi"
    }
    network_policy = {
      ingress = "AllowSameNamespace"
      egress  = "AllowAll"
    }
    # Opt in to the foundation's shared managed Redis.
    redis_enabled = true
    labels        = { "onek8s.io/cost-center" = "alpha-1001" }
  }
  team-beta = {}
}
