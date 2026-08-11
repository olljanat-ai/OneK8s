# Dependency direction: tenants read foundation outputs, never the reverse.
data "terraform_remote_state" "foundation" {
  backend = "gcs"

  config = {
    bucket = var.foundation_state.bucket
    prefix = var.foundation_state.prefix
  }
}

module "tenant" {
  source   = "../../modules/tenant-namespace/gcp"
  for_each = var.tenants

  tenant_name      = each.key
  environment      = var.environment
  project_id       = data.terraform_remote_state.foundation.outputs.project_id
  project_number   = data.terraform_remote_state.foundation.outputs.project_number
  cluster_name     = data.terraform_remote_state.foundation.outputs.cluster_name
  cluster_location = data.terraform_remote_state.foundation.outputs.cluster_location

  quota            = each.value.quota
  namespace_labels = each.value.labels
}
