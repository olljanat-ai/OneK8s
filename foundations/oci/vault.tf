# OCI Vault is both the key manager and the secret store: tenant secrets are
# created in this vault (Secrets service) and encrypted with the master key
# below. Tenant identities get read access to their own name prefix only —
# see modules/tenant-namespace/oci.
#
# Note: deleting a vault is a scheduled operation with a mandatory waiting
# period (7-30 days); `terraform destroy` schedules the deletion rather than
# removing the vault immediately.
resource "oci_kms_vault" "secrets" {
  compartment_id = var.compartment_ocid
  display_name   = "kv-${local.name}"
  vault_type     = "DEFAULT"
  freeform_tags  = local.tags
}

resource "oci_kms_key" "secrets" {
  compartment_id      = var.compartment_ocid
  display_name        = "key-${local.name}-secrets"
  management_endpoint = oci_kms_vault.secrets.management_endpoint
  protection_mode     = "SOFTWARE"
  freeform_tags       = local.tags

  key_shape {
    algorithm = "AES"
    length    = 32
  }
}
