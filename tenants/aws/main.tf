# Dependency direction: tenants read foundation outputs, never the reverse.
data "terraform_remote_state" "foundation" {
  backend = "s3"

  config = {
    bucket = var.foundation_state.bucket
    key    = var.foundation_state.key
    region = var.foundation_state.region
  }
}

module "tenant" {
  source   = "../../modules/tenant-namespace/aws"
  for_each = var.tenants

  tenant_name         = each.key
  environment         = var.environment
  oidc_issuer_url     = data.terraform_remote_state.foundation.outputs.oidc_issuer_url
  oidc_provider_arn   = data.terraform_remote_state.foundation.outputs.oidc_provider_arn
  region              = data.terraform_remote_state.foundation.outputs.region
  account_id          = data.terraform_remote_state.foundation.outputs.account_id
  secrets_kms_key_arn = data.terraform_remote_state.foundation.outputs.secrets_kms_key_arn

  quota            = each.value.quota
  namespace_labels = each.value.labels
}
