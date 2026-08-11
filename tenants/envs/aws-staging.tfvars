cloud       = "aws"
environment = "staging"

foundation_state = {
  bucket = "onek8s-tfstate"
  key    = "foundations/aws/staging.tfstate"
  region = "eu-west-1"
}

tenants = {
  team-alpha = {}
}
