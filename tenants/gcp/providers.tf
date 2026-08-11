provider "google" {
  project = data.terraform_remote_state.foundation.outputs.project_id
  region  = data.terraform_remote_state.foundation.outputs.cluster_location
}

data "google_client_config" "default" {}

provider "kubernetes" {
  host                   = "https://${data.terraform_remote_state.foundation.outputs.cluster_endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(data.terraform_remote_state.foundation.outputs.cluster_ca_certificate)
}
