cloud       = "gcp"
environment = "staging"

foundation_state = {
  bucket = "onek8s-tfstate"
  prefix = "foundations/gcp/staging"
}

tenants = {
  team-alpha = {}
}
