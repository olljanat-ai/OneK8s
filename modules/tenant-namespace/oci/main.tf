locals {
  namespace = var.tenant_name

  # Secrets in the shared vault are namespaced by convention:
  # "<tenant>-<secret-name>". The target.secret.name condition below makes
  # this convention a hard security boundary.
  secret_prefix = "${var.tenant_name}-"

  # OKE Workload Identity has no intermediate identity object: the principal
  # *is* the (cluster, namespace, service account) tuple, asserted by OKE and
  # matched directly in the policy conditions below. There is therefore no
  # role/UAMI/GSA to create and nothing to annotate on the ServiceAccount —
  # unlike the other three clouds, the binding lives entirely in IAM.
  workload_conditions = join(", ", [
    "request.principal.type = 'workload'",
    "request.principal.cluster_id = '${var.cluster_id}'",
    "request.principal.namespace = '${local.namespace}'",
    "request.principal.service_account = '${var.service_account_name}'",
    # Pattern match, not equality: the tenant owns every secret under its
    # prefix. Any other tenant's secrets fail the condition and are invisible.
    "target.secret.name = /${local.secret_prefix}*/",
  ])
}

# --- Least-privilege secret access -------------------------------------------
# "read secret-bundles" is what actually returns a secret's value;
# "read secrets" covers the metadata lookup ESO performs alongside it. Both
# carry the same prefix condition. Neither grants list/enumerate across the
# compartment: a collection request has no single target secret name, so the
# condition cannot be satisfied and cross-tenant discovery stays blocked.
resource "oci_identity_policy" "tenant_secrets" {
  provider = oci.home

  compartment_id = var.compartment_id
  name           = "tenant-${var.tenant_name}-${var.environment}-secrets"
  description    = "Tenant ${var.tenant_name} (${var.environment}): read own '${local.secret_prefix}' secrets via OKE workload identity"

  statements = [
    "Allow any-user to read secret-bundles in compartment id ${var.compartment_id} where all {${local.workload_conditions}}",
    "Allow any-user to read secrets in compartment id ${var.compartment_id} where all {${local.workload_conditions}}",
  ]
}

# --- Kubernetes-side resources (namespace, SA, namespaced SecretStore) -------
module "common" {
  source = "../common"

  tenant_name           = var.tenant_name
  namespace             = local.namespace
  create_namespace      = true
  namespace_labels      = var.namespace_labels
  pod_security_standard = var.pod_security_standard
  quota                 = var.quota

  service_account_name = var.service_account_name

  ingress_controller_namespace = var.ingress_controller_namespace

  secret_store_provider = {
    oracle = {
      vault         = var.vault_id
      region        = var.region
      principalType = "Workload"
      serviceAccountRef = {
        name = var.service_account_name
      }
    }
  }
}
