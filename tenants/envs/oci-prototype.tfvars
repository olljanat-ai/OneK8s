cloud       = "oci"
environment = "prototype"

# OCI Object Storage via its S3-compatible endpoint; replace <namespace> with
# your Object Storage namespace (`oci os ns get`).
foundation_state = {
  bucket = "onek8s-tfstate"
  key    = "foundations/oci/prototype.tfstate"
  region = "eu-frankfurt-1"

  endpoints = {
    s3 = "https://<namespace>.compat.objectstorage.eu-frankfurt-1.oraclecloud.com"
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
