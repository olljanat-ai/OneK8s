# Customer-managed KMS key for all tenant secrets in Secrets Manager.
# Tenant roles get kms:Decrypt restricted to use *via* Secrets Manager, so
# the key itself cannot be used directly.
resource "aws_kms_key" "secrets" {
  description             = "CMK for ${local.name} tenant secrets in Secrets Manager"
  deletion_window_in_days = 14
  enable_key_rotation     = true
}

resource "aws_kms_alias" "secrets" {
  name          = "alias/${local.name}-secrets"
  target_key_id = aws_kms_key.secrets.key_id
}
