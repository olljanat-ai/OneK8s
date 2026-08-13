cloud       = "oci"
environment = "prototype"

# OCI Object Storage via its S3-compatible endpoint. These coordinates must
# match foundations/oci/backend/prototype.hcl — that is where the foundation
# writes the state this stack reads.
foundation_state = {
  bucket = "onek8s-tfstate"
  key    = "foundations/oci/prototype.tfstate"
  region = "eu-stockholm-1"

  endpoints = {
    s3 = "https://ax9e2kehb4lc.compat.objectstorage.eu-stockholm-1.oraclecloud.com"
  }

  skip_region_validation      = true
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_s3_checksum            = true
  use_path_style              = true
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
    labels = { "onek8s.io/cost-center" = "alpha-1001" }
  }
  team-beta = {}
}
