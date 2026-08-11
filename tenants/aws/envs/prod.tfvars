environment = "prod"
region      = "eu-west-1"

foundation_state = {
  bucket = "onek8s-tfstate"
  key    = "foundations/aws/prod.tfstate"
  region = "eu-west-1"
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
