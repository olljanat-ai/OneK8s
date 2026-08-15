locals {
  # Pod Security Admission, in six labels. The API server does the enforcing
  # itself — every pod created in the namespace is checked against the level on
  # admission, whoever creates it and whatever wrote the manifest — so this is
  # the one guardrail on the list that needs nothing installed in the cluster
  # and cannot be bypassed by a workload that simply forgets to opt in.
  #
  # It is computed here, in the dispatcher, rather than in common/: Azure's
  # namespace is an ARM-managed object created by azure/, not a
  # kubernetes_namespace in common/, and a guardrail that quietly skipped AKS
  # would be worse than none.
  #
  # enforce rejects, audit records in the audit log, warn tells whoever ran
  # kubectl. All three are set: a rejection alone tells the tenant they were
  # stopped, the other two tell the platform what was tried.
  pod_security_labels = {
    "pod-security.kubernetes.io/enforce"         = var.pod_security.enforce
    "pod-security.kubernetes.io/enforce-version" = var.pod_security.version
    "pod-security.kubernetes.io/audit"           = var.pod_security.audit
    "pod-security.kubernetes.io/audit-version"   = var.pod_security.version
    "pod-security.kubernetes.io/warn"            = var.pod_security.warn
    "pod-security.kubernetes.io/warn-version"    = var.pod_security.version
  }

  # Tenant labels last, so an exception is written where the tenant is
  # declared and is visible in a diff, instead of being hidden in a module.
  namespace_labels = merge(local.pod_security_labels, var.namespace_labels)
}

# Dispatcher: exactly one cloud-specific implementation is instantiated,
# selected by var.cloud. Arguments of unselected branches are not evaluated,
# so var.foundation only needs the keys of the selected cloud.
module "azure" {
  source = "./azure"
  count  = var.cloud == "azure" ? 1 : 0

  tenant_name          = var.tenant_name
  environment          = var.environment
  resource_group_name  = var.foundation.resource_group_name
  location             = var.foundation.location
  aks_cluster_id       = var.foundation.cluster_id
  oidc_issuer_url      = var.foundation.oidc_issuer_url
  key_vault_id         = var.foundation.key_vault_id
  key_vault_uri        = var.foundation.key_vault_uri
  quota                = var.quota
  namespace_labels     = local.namespace_labels
  service_account_name = var.service_account_name

  ingress_controller_namespace = var.ingress_controller_namespace
}

module "aws" {
  source = "./aws"
  count  = var.cloud == "aws" ? 1 : 0

  tenant_name          = var.tenant_name
  environment          = var.environment
  oidc_issuer_url      = var.foundation.oidc_issuer_url
  oidc_provider_arn    = var.foundation.oidc_provider_arn
  region               = var.foundation.region
  account_id           = var.foundation.account_id
  secrets_kms_key_arn  = var.foundation.secrets_kms_key_arn
  quota                = var.quota
  namespace_labels     = local.namespace_labels
  service_account_name = var.service_account_name

  ingress_controller_namespace = var.ingress_controller_namespace
}

module "gcp" {
  source = "./gcp"
  count  = var.cloud == "gcp" ? 1 : 0

  tenant_name          = var.tenant_name
  environment          = var.environment
  project_id           = var.foundation.project_id
  project_number       = var.foundation.project_number
  cluster_name         = var.foundation.cluster_name
  cluster_location     = var.foundation.cluster_location
  quota                = var.quota
  namespace_labels     = local.namespace_labels
  service_account_name = var.service_account_name

  ingress_controller_namespace = var.ingress_controller_namespace
}

# OCI needs an explicit providers block: its IAM policies must be written
# through the home-region provider alias, which is never inherited implicitly.
module "oci" {
  source = "./oci"
  count  = var.cloud == "oci" ? 1 : 0

  providers = {
    oci        = oci
    oci.home   = oci.home
    kubernetes = kubernetes
  }

  tenant_name          = var.tenant_name
  environment          = var.environment
  compartment_id       = var.foundation.compartment_id
  cluster_id           = var.foundation.cluster_id
  vault_id             = var.foundation.vault_id
  region               = var.foundation.region
  quota                = var.quota
  namespace_labels     = local.namespace_labels
  service_account_name = var.service_account_name

  ingress_controller_namespace = var.ingress_controller_namespace
}
