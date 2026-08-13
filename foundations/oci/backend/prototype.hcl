# OCI Object Storage through its S3-compatible endpoint. Bootstrap the bucket
# once, out of band, and replace <namespace> with your Object Storage
# namespace (`oci os ns get`). Authenticate with a Customer Secret Key
# (AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY).
bucket = "onek8s-tfstate"
key    = "foundations/oci/prototype.tfstate"
region = "eu-frankfurt-1"

endpoints = {
  s3 = "https://<namespace>.compat.objectstorage.eu-frankfurt-1.oraclecloud.com"
}

# OCI is not AWS: skip the AWS-specific validation and checksum behaviour.
skip_region_validation      = true
skip_credentials_validation = true
skip_requesting_account_id  = true
skip_s3_checksum            = true
use_path_style              = true
